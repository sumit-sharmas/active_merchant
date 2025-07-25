require 'active_merchant/billing/gateways/paypal/paypal_common_api'
require 'active_merchant/billing/gateways/paypal/paypal_recurring_api'
require 'active_merchant/billing/gateways/paypal_express'

module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class PaypalGateway < Gateway
      version '2.0'

      include PaypalCommonAPI
      include PaypalRecurringApi

      self.supported_countries = %w[CA NZ GB US]
      self.supported_cardtypes = %i[visa master american_express discover]
      self.homepage_url = 'https://www.paypal.com/us/webapps/mpp/paypal-payments-pro'
      self.display_name = 'PayPal Payments Pro (US)'

      def authorize(money, credit_card_or_referenced_id, options = {})
        requires!(options, :ip)
        commit define_transaction_type(credit_card_or_referenced_id), build_sale_or_authorization_request('Authorization', money, credit_card_or_referenced_id, options)
      end

      def purchase(money, credit_card_or_referenced_id, options = {})
        requires!(options, :ip)
        commit define_transaction_type(credit_card_or_referenced_id), build_sale_or_authorization_request('Sale', money, credit_card_or_referenced_id, options)
      end

      def verify(credit_card, options = {})
        if %w(visa master).include?(credit_card.brand)
          authorize(0, credit_card, options)
        else
          MultiResponse.run(:use_first_response) do |r|
            r.process { authorize(100, credit_card, options) }
            r.process(:ignore_result) { void(r.authorization, options) }
          end
        end
      end

      def express
        @express ||= PaypalExpressGateway.new(@options)
      end

      private

      def define_transaction_type(transaction_arg)
        if transaction_arg.is_a?(String)
          return 'DoReferenceTransaction'
        else
          return 'DoDirectPayment'
        end
      end

      def build_sale_or_authorization_request(action, money, credit_card_or_referenced_id, options)
        transaction_type = define_transaction_type(credit_card_or_referenced_id)
        reference_id = credit_card_or_referenced_id if transaction_type == 'DoReferenceTransaction'

        billing_address = options[:billing_address] || options[:address]
        currency_code = options[:currency] || currency(money)

        xml = Builder::XmlMarkup.new indent: 2
        xml.tag! transaction_type + 'Req', 'xmlns' => PAYPAL_NAMESPACE do
          xml.tag! transaction_type + 'Request', 'xmlns:n2' => EBAY_NAMESPACE do
            xml.tag! 'n2:Version', api_version(options)
            xml.tag! 'n2:' + transaction_type + 'RequestDetails' do
              xml.tag! 'n2:ReferenceID', reference_id if transaction_type == 'DoReferenceTransaction'
              xml.tag! 'n2:PaymentAction', action
              add_descriptors(xml, options)
              add_payment_details(xml, money, currency_code, options)
              add_credit_card(xml, credit_card_or_referenced_id, billing_address, options) unless transaction_type == 'DoReferenceTransaction'
              xml.tag! 'n2:IPAddress', options[:ip]
            end
          end
        end

        xml.target!
      end

      def api_version(options)
        return API_VERSION_3DS2 if options.dig(:three_d_secure, :version) =~ /^2/

        API_VERSION
      end

      def add_credit_card(xml, credit_card, address, options)
        xml.tag! 'n2:CreditCard' do
          xml.tag! 'n2:CreditCardType', credit_card_type(card_brand(credit_card))
          xml.tag! 'n2:CreditCardNumber', credit_card.number
          xml.tag! 'n2:ExpMonth', format(credit_card.month, :two_digits)
          xml.tag! 'n2:ExpYear', format(credit_card.year, :four_digits)
          xml.tag! 'n2:CVV2', credit_card.verification_value unless credit_card.verification_value.blank?

          xml.tag! 'n2:CardOwner' do
            xml.tag! 'n2:PayerName' do
              xml.tag! 'n2:FirstName', credit_card.first_name
              xml.tag! 'n2:LastName', credit_card.last_name
            end

            xml.tag! 'n2:Payer', options[:email]
            add_address(xml, 'n2:Address', address)
          end

          add_three_d_secure(xml, options) if options[:three_d_secure]
        end
      end

      def add_descriptors(xml, options)
        xml.tag! 'n2:SoftDescriptor', options[:soft_descriptor] unless options[:soft_descriptor].blank?
        xml.tag! 'n2:SoftDescriptorCity', options[:soft_descriptor_city] unless options[:soft_descriptor_city].blank?
      end

      def add_three_d_secure(xml, options)
        three_d_secure = options[:three_d_secure]
        xml.tag! 'ThreeDSecureRequest' do
          xml.tag! 'MpiVendor3ds', 'Y'
          xml.tag! 'AuthStatus3ds', three_d_secure[:authentication_response_status] || three_d_secure[:trans_status] if three_d_secure[:authentication_response_status] || three_d_secure[:trans_status]
          xml.tag! 'Cavv', three_d_secure[:cavv] unless three_d_secure[:cavv].blank?
          xml.tag! 'Eci3ds', three_d_secure[:eci] unless three_d_secure[:eci].blank?
          xml.tag! 'Xid', three_d_secure[:xid] unless three_d_secure[:xid].blank?
          xml.tag! 'ThreeDSVersion', three_d_secure[:version] unless three_d_secure[:version].blank?
          xml.tag! 'DSTransactionId', three_d_secure[:ds_transaction_id] unless three_d_secure[:ds_transaction_id].blank?
        end
      end

      def credit_card_type(type)
        case type
        when 'visa'             then 'Visa'
        when 'master'           then 'MasterCard'
        when 'discover'         then 'Discover'
        when 'american_express' then 'Amex'
        end
      end

      def build_response(success, message, response, options = {})
        Response.new(success, message, response, options)
      end
    end
  end
end
