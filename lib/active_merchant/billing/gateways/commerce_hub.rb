module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class CommerceHubGateway < Gateway
      version 'v1'

      self.test_url = 'https://connect-cert.fiservapps.com/ch'
      self.live_url = 'https://connect.fiservapis.com/ch'

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = %i[visa master american_express discover]

      self.homepage_url = 'https://developer.fiserv.com/product/CommerceHub'
      self.display_name = 'CommerceHub'

      STANDARD_ERROR_CODE_MAPPING = {}

      SCHEDULED_REASON_TYPES = %w(recurring installment)
      ENDPOINTS = {
        'sale' => "/payments/#{fetch_version}/charges",
        'void' => "/payments/#{fetch_version}/cancels",
        'refund' => "/payments/#{fetch_version}/refunds",
        'vault' => "/payments-vas/#{fetch_version}/tokens",
        'verify' => "/payments-vas/#{fetch_version}/accounts/verification"
      }

      def initialize(options = {})
        requires!(options, :api_key, :api_secret, :merchant_id, :terminal_id)
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        options[:capture_flag] = true
        options[:create_token] = false

        add_transaction_details(post, options, 'sale')
        build_purchase_and_auth_request(post, money, payment, options)

        commit('sale', post, options)
      end

      def authorize(money, payment, options = {})
        post = {}
        options[:capture_flag] = false
        options[:create_token] = false

        add_transaction_details(post, options, 'sale')
        build_purchase_and_auth_request(post, money, payment, options)

        commit('sale', post, options)
      end

      def capture(money, authorization, options = {})
        post = {}
        options[:capture_flag] = true
        add_invoice(post, money, options)
        add_transaction_details(post, options, 'capture')
        add_reference_transaction_details(post, authorization, options, :capture)
        add_dynamic_descriptors(post, options)

        commit('sale', post, options)
      end

      def refund(money, authorization, options = {})
        post = {}
        add_invoice(post, money, options) if money
        add_transaction_details(post, options)
        add_reference_transaction_details(post, authorization, options, :refund)

        commit('refund', post, options)
      end

      def credit(money, payment_method, options = {})
        post = {}
        add_invoice(post, money, options)
        add_transaction_details(post, options)
        add_transaction_interaction(post, options)
        add_payment(post, payment_method, options)

        commit('refund', post, options)
      end

      def void(authorization, options = {})
        post = {}
        add_transaction_details(post, options)
        add_reference_transaction_details(post, authorization, options, :void)

        commit('void', post, options)
      end

      def store(credit_card, options = {})
        post = {}
        add_payment(post, credit_card, options)
        add_billing_address(post, credit_card, options)
        add_transaction_details(post, options)
        add_transaction_interaction(post, options)

        commit('vault', post, options)
      end

      def verify(credit_card, options = {})
        post = {}
        add_payment(post, credit_card, options)
        add_billing_address(post, credit_card, options)
        add_transaction_details(post, options, 'verify')

        commit('verify', post, options)
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Authorization: )[a-zA-Z0-9+./=]+), '\1[FILTERED]').
          gsub(%r((Api-Key: )\w+), '\1[FILTERED]').
          gsub(%r(("apiKey\\?":\\?")\w+), '\1[FILTERED]').
          gsub(%r(("cardData\\?":\\?")\d+), '\1[FILTERED]').
          gsub(%r(("securityCode\\?":\\?")\d+), '\1[FILTERED]').
          gsub(%r(("cavv\\?":\\?")\w+), '\1[FILTERED]')
      end

      private

      def add_three_d_secure(post, options)
        return unless three_d_secure = options[:three_d_secure]

        post[:additionalData3DS] = {
          dsTransactionId: three_d_secure[:ds_transaction_id],
          authenticationStatus: three_d_secure[:authentication_response_status],
          serverTransactionId: three_d_secure[:three_ds_server_trans_id],
          acsTransactionId: three_d_secure[:acs_transaction_id],
          mpiData: {
            cavv: three_d_secure[:cavv],
            eci: three_d_secure[:eci],
            xid: three_d_secure[:xid]
          }.compact,
          versionData: { recommendedVersion: three_d_secure[:version] }
        }.compact
      end

      def add_transaction_interaction(post, options)
        post[:transactionInteraction] = {}
        post[:transactionInteraction][:origin] = options[:origin] || 'ECOM'
        post[:transactionInteraction][:eciIndicator] = map_ecommerce_indicator(options)
        post[:transactionInteraction][:posConditionCode] = options[:pos_condition_code] || 'CARD_NOT_PRESENT_ECOM'
        post[:transactionInteraction][:posEntryMode] = (options[:pos_entry_mode] || 'MANUAL') unless options[:encryption_data].present?
        post[:transactionInteraction][:additionalPosInformation] = {}
        post[:transactionInteraction][:additionalPosInformation][:dataEntrySource] = options[:data_entry_source] || 'UNSPECIFIED'
      end

      def add_transaction_details(post, options, action = nil)
        details = {
          captureFlag: options[:capture_flag],
          createToken: options[:create_token],
          physicalGoodsIndicator: [true, 'true'].include?(options[:physical_goods_indicator])
        }

        if %w(sale verify).include?(action)
          details[:merchantOrderId] = options[:order_id]
          details[:merchantTransactionId] = rand.to_s[2..13]
        end

        details[:merchantInvoiceNumber] = options[:order_id] if action != 'capture'

        post[:transactionDetails] = details.compact
      end

      def add_billing_address(post, payment, options)
        return unless billing = options[:billing_address]

        billing_address = {}
        name_from_address(billing_address, billing) || name_from_payment(billing_address, payment)
        address = {}
        address[:street] = billing[:address1] if billing[:address1]
        address[:houseNumberOrName] = billing[:address2] if billing[:address2]
        address[:recipientNameOrAddress] = billing[:name] if billing[:name]
        address[:city] = billing[:city] if billing[:city]
        address[:stateOrProvince] = billing[:state] if billing[:state]
        address[:postalCode] = billing[:zip] if billing[:zip]
        address[:country] = billing[:country] if billing[:country]

        billing_address[:address] = address unless address.empty?
        if billing[:phone_number]
          billing_address[:phone] = {}
          billing_address[:phone][:phoneNumber] = billing[:phone_number]
        end
        post[:billingAddress] = billing_address
      end

      def name_from_payment(billing_address, payment)
        return unless payment.respond_to?(:first_name) && payment.respond_to?(:last_name)

        billing_address[:firstName] = payment.first_name if payment.first_name
        billing_address[:lastName] = payment.last_name if payment.last_name
      end

      def name_from_address(billing_address, billing)
        return unless address = billing

        first_name, last_name = split_names(address[:name]) if address[:name]

        billing_address[:firstName] = first_name if first_name
        billing_address[:lastName] = last_name if last_name
      end

      def add_shipping_address(post, options)
        return unless shipping = options[:shipping_address]

        shipping_address = {}
        address = {}
        address[:street] = shipping[:address1] if shipping[:address1]
        address[:houseNumberOrName] = shipping[:address2] if shipping[:address2]
        address[:recipientNameOrAddress] = shipping[:name] if shipping[:name]
        address[:city] = shipping[:city] if shipping[:city]
        address[:stateOrProvince] = shipping[:state] if shipping[:state]
        address[:postalCode] = shipping[:zip] if shipping[:zip]
        address[:country] = shipping[:country] if shipping[:country]

        shipping_address[:address] = address unless address.empty?
        if shipping[:phone_number]
          shipping_address[:phone] = {}
          shipping_address[:phone][:phoneNumber] = shipping[:phone_number]
        end
        post[:shippingAddress] = shipping_address
      end

      def build_purchase_and_auth_request(post, money, payment, options)
        add_three_d_secure(post, options)
        add_invoice(post, money, options)
        add_payment(post, payment, options)
        add_stored_credentials(post, options)
        add_transaction_interaction(post, options)
        add_billing_address(post, payment, options)
        add_shipping_address(post, options)
        add_dynamic_descriptors(post, options)
      end

      def add_dynamic_descriptors(post, options)
        dynamic_descriptors_fields = %i[mcc merchant_name customer_service_number service_entitlement dynamic_descriptors_address]
        return unless dynamic_descriptors_fields.any? { |key| options.include?(key) }

        dynamic_descriptors = {}
        dynamic_descriptors[:mcc] = options[:mcc] if options[:mcc]
        dynamic_descriptors[:merchantName] = options[:merchant_name] if options[:merchant_name]
        dynamic_descriptors[:customerServiceNumber] = options[:customer_service_number] if options[:customer_service_number]
        dynamic_descriptors[:serviceEntitlement] = options[:service_entitlement] if options[:service_entitlement]
        dynamic_descriptors[:address] = options[:dynamic_descriptors_address] if options[:dynamic_descriptors_address]

        post[:dynamicDescriptors] = dynamic_descriptors
      end

      def add_reference_transaction_details(post, authorization, options, action = nil)
        reference_details = {}
        _merchant_reference, transaction_id = authorization.include?('|') ? authorization.split('|') : [nil, authorization]

        reference_details[:referenceTransactionId] = transaction_id
        reference_details[:referenceTransactionType] = (options[:reference_transaction_type] || 'CHARGES') unless action == :capture
        post[:referenceTransactionDetails] = reference_details.compact
      end

      def add_invoice(post, money, options)
        post[:amount] = {
          total: amount(money).to_f,
          currency: options[:currency] || self.default_currency
        }
      end

      def add_stored_credentials(post, options)
        return unless stored_credential = options[:stored_credential]

        post[:storedCredentials] = {}
        post[:storedCredentials][:sequence] = stored_credential[:initial_transaction] ? 'FIRST' : 'SUBSEQUENT'
        post[:storedCredentials][:initiator] = stored_credential[:initiator] == 'merchant' ? 'MERCHANT' : 'CARD_HOLDER'
        post[:storedCredentials][:scheduled] = SCHEDULED_REASON_TYPES.include?(stored_credential[:reason_type])
        post[:storedCredentials][:schemeReferenceTransactionId] = options[:scheme_reference_transaction_id] || stored_credential[:network_transaction_id]
      end

      def add_credit_card(source, payment, options)
        source[:sourceType] = 'PaymentCard'
        source[:card] = {}
        source[:card][:cardData] = payment.number
        source[:card][:expirationMonth] = format(payment.month, :two_digits) if payment.month
        source[:card][:expirationYear] = format(payment.year, :four_digits) if payment.year
        if payment.verification_value
          source[:card][:securityCode] = payment.verification_value
          source[:card][:securityCodeIndicator] = 'PROVIDED'
        end
      end

      def add_payment_token(source, payment, options)
        source[:sourceType] = 'PaymentToken'
        source[:tokenData] = payment
        source[:tokenSource] = options[:token_source] if options[:token_source]
        if options[:card_expiration_month] || options[:card_expiration_year]
          source[:card] = {}
          source[:card][:expirationMonth] = options[:card_expiration_month] if options[:card_expiration_month]
          source[:card][:expirationYear] = options[:card_expiration_year] if options[:card_expiration_year]
        end
      end

      def add_decrypted_wallet(source, payment, options)
        source[:sourceType] = 'DecryptedWallet'
        source[:card] = {}
        source[:card][:cardData] = payment.number
        source[:card][:expirationMonth] = format(payment.month, :two_digits)
        source[:card][:expirationYear] = format(payment.year, :four_digits)
        source[:cavv] = payment.payment_cryptogram
        source[:walletType] = payment.source.to_s.upcase
      end

      def add_network_token(source, payment, options)
        source[:sourceType] = 'PaymentToken'
        source[:tokenData] = payment.number
        source[:tokenSource] = 'NETWORK_TOKEN'
        source[:cryptogram] = payment.payment_cryptogram
        source[:card] = {
          expirationMonth: format(payment.month, :two_digits),
          expirationYear: format(payment.year, :four_digits)
        }
      end

      def add_payment(post, payment, options = {})
        source = {}

        if payment.is_a?(String)
          add_payment_token(source, payment, options)
        elsif payment.mobile_wallet?
          add_decrypted_wallet(source, payment, options)
        elsif payment.network_token?
          add_network_token(source, payment, options)
        elsif options[:encryption_data].present?
          source[:sourceType] = 'PaymentCard'
          source[:encryptionData] = options[:encryption_data]
        elsif payment.is_a?(CreditCard)
          add_credit_card(source, payment, options)
        end
        post[:source] = source
      end

      def parse(body)
        JSON.parse(body)
      end

      def headers(request, options)
        time = DateTime.now.strftime('%Q').to_s
        client_request_id = options[:client_request_id] || SecureRandom.uuid
        raw_signature = @options[:api_key] + client_request_id.to_s + time + request
        hmac = OpenSSL::HMAC.digest('sha256', @options[:api_secret], raw_signature)
        signature = Base64.strict_encode64(hmac.to_s).to_s
        custom_headers = options.fetch(:headers_identifiers, {})
        {
          'Client-Request-Id' => client_request_id,
          'Api-Key' => @options[:api_key],
          'Timestamp' => time,
          'Accept-Language' => 'application/json',
          'Auth-Token-Type' => 'HMAC',
          'Content-Type' => 'application/json',
          'Accept' => 'application/json',
          'Authorization' => signature
        }.merge!(custom_headers)
      end

      def add_merchant_details(post)
        post[:merchantDetails] = {}
        post[:merchantDetails][:terminalId] = @options[:terminal_id]
        post[:merchantDetails][:merchantId] = @options[:merchant_id]
      end

      def commit(action, parameters, options)
        url = (test? ? test_url : live_url) + ENDPOINTS[action]
        add_merchant_details(parameters)
        response = parse(ssl_post(url, parameters.to_json, headers(parameters.to_json, options)))

        Response.new(
          success_from(response, action),
          message_from(response, action),
          response,
          authorization: authorization_from(action, response, options),
          test: test?,
          error_code: error_code_from(response, action),
          avs_result: AVSResult.new(code: get_avs_cvv(response, 'avs')),
          cvv_result: CVVResult.new(get_avs_cvv(response, 'cvv'))
        )
      end

      def get_avs_cvv(response, type = 'avs')
        response.dig(
          'paymentReceipt',
          'processorResponseDetails',
          'bankAssociationDetails',
          'avsSecurityCodeResponse',
          'association',
          type == 'avs' ? 'avsCode' : 'securityCodeResponse'
        )
      end

      def handle_response(response)
        case response.code.to_i
        when 200...300, 400, 401, 429
          response.body
        else
          raise ResponseError.new(response)
        end
      end

      def success_from(response, action = nil)
        return message_from(response, action) == 'VERIFIED' if action == 'verify'

        (response.dig('paymentReceipt', 'processorResponseDetails', 'responseCode') || response.dig('paymentTokens', 0, 'tokenResponseCode')) == '000'
      end

      def message_from(response, action = nil)
        return response.dig('error', 0, 'message') if response['error'].present?
        return response.dig('gatewayResponse', 'transactionState') if action == 'verify'

        response.dig('paymentReceipt', 'processorResponseDetails', 'responseMessage') || response.dig('gatewayResponse', 'transactionType')
      end

      def authorization_from(action, response, options)
        case action
        when 'vault'
          response.dig('paymentTokens', 0, 'tokenData')
        when 'sale'
          [options[:order_id] || '', response.dig('gatewayResponse', 'transactionProcessingDetails', 'transactionId')].join('|')
        else
          response.dig('gatewayResponse', 'transactionProcessingDetails', 'transactionId')
        end
      end

      def error_code_from(response, action)
        response.dig('error', 0, 'code') unless success_from(response, action)
      end

      def map_ecommerce_indicator(options)
        return options[:eci_indicator] if options[:eci_indicator]
        return 'CHANNEL_ENCRYPTED'     unless options[:three_d_secure]

        case options[:three_d_secure][:eci]
        when '2', '02', '5', '05'
          'SECURE_ECOM'
        when '01', '1', '06', '6'
          'NON_AUTH_ECOM'
        else
          'CHANNEL_ENCRYPTED'
        end
      end
    end
  end
end
