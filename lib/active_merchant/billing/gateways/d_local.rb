module ActiveMerchant # :nodoc:
  module Billing # :nodoc:
    class DLocalGateway < Gateway
      self.test_url = 'https://sandbox.dlocal.com'
      self.live_url = 'https://api.dlocal.com'

      self.supported_countries = %w[AR BD BO BR CL CM CN CO CR DO EC EG GH GT IN ID JP KE MY MX MA NG PA PY PE PH SN SV TH TR TZ UG UY VN ZA]
      self.default_currency = 'USD'
      self.supported_cardtypes = %i[visa master american_express discover jcb diners_club maestro naranja cabal elo alia carnet patagonia_365 tarjeta_sol]

      self.homepage_url = 'https://dlocal.com/'
      self.display_name = 'dLocal'

      def initialize(options = {})
        requires!(options, :login, :trans_key, :secret_key)
        super
      end

      def purchase(money, payment, options = {})
        post = {}
        add_auth_purchase_params(post, money, payment, 'purchase', options)
        add_three_ds(post, options)

        commit('purchase', post, options)
      end

      def authorize(money, payment, options = {})
        post = {}
        add_auth_purchase_params(post, money, payment, 'authorize', options)
        add_three_ds(post, options)
        post[:card][:verify] = true if options[:verify].to_s == 'true'

        commit('authorize', post, options)
      end

      def capture(money, authorization, options = {})
        post = {}
        post[:authorization_id] = authorization
        add_invoice(post, money, options) if money
        commit('capture', post, options)
      end

      def refund(money, authorization, options = {})
        post = {}
        add_description(post, options)
        post[:payment_id] = authorization
        post[:notification_url] = options[:notification_url]
        add_invoice(post, money, options) if money
        commit('refund', post, options)
      end

      def void(authorization, options = {})
        post = {}
        post[:authorization_id] = authorization
        commit('void', post, options)
      end

      def verify(credit_card, options = {})
        authorize(0, credit_card, options.merge(verify: 'true'))
      end

      def inquire(authorization, options = {})
        post = {}
        post[:payment_id] = authorization
        action = authorization ? 'status' : 'orders'
        commit(action, post, options)
      end

      def supports_scrubbing?
        true
      end

      def supports_network_tokenization?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((X-Trans-Key: )\w+), '\1[FILTERED]').
          gsub(%r((\"number\\\":\\\")\d+), '\1[FILTERED]').
          gsub(%r((\"cvv\\\":\\\")\d+), '\1[FILTERED]')
      end

      private

      def add_auth_purchase_params(post, money, card, action, options)
        add_invoice(post, money, options)
        post[:payment_method_id] = 'CARD'
        post[:payment_method_flow] = 'DIRECT'
        add_country(post, card, options)
        add_payer(post, card, options)
        add_card(post, card, action, options)
        add_additional_data(post, options)
        add_description(post, options)
        post[:order_id] = options[:order_id] || generate_unique_id
        post[:original_order_id] = options[:original_order_id] if options[:original_order_id]
      end

      def add_invoice(post, money, options)
        post[:amount] = amount(money)
        post[:currency] = (options[:currency] || currency(money))
      end

      def add_description(post, options)
        post[:description] = options[:description] if options[:description]
      end

      def add_additional_data(post, options)
        post[:additional_risk_data] = options[:additional_data]
      end

      def add_country(post, card, options)
        return unless (address = options[:billing_address] || options[:address]) || options[:country]

        country = options[:country] ? lookup_country_code(options[:country]) : lookup_country_code(address[:country])
        post[:country] = country
      end

      def lookup_country_code(country_field)
        Country.find(country_field).code(:alpha2).value
      rescue InvalidCountryCodeError
        nil
      end

      def add_payer(post, card, options)
        address = options[:billing_address] || options[:address]
        phone_number = address[:phone] || address[:phone_number] if address

        post[:payer] = {}
        post[:payer][:name] = card.name
        post[:payer][:email] = options[:email] if options[:email]
        post[:payer][:birth_date] = options[:birth_date] if options[:birth_date]
        post[:payer][:phone] = phone_number if phone_number
        post[:payer][:document] = options[:document] if options[:document]
        post[:payer][:document2] = options[:document2] if options[:document2]
        post[:payer][:user_reference] = options[:user_reference] if options[:user_reference]
        post[:payer][:event_uuid] = options[:device_id] if options[:device_id]
        post[:payer][:ip] = options[:ip] if options[:ip]
        post[:payer][:address] = add_address(post, card, options)
      end

      def add_address(post, card, options)
        return unless address = options[:billing_address] || options[:address]

        address_object = {}
        address_object[:state] = address[:state] if address[:state]
        address_object[:city] = address[:city] if address[:city]
        address_object[:zip_code] = address[:zip] if address[:zip]
        address_object[:street] = address[:street] || parse_street(address) if parse_street(address)
        address_object[:number] = address[:number] || parse_house_number(address) if parse_house_number(address)
        address_object
      end

      def parse_street(address)
        return unless address[:address1]

        street = address[:address1].split(/\s+/).keep_if { |x| x !~ /\d/ }.join(' ')
        street.empty? ? nil : street
      end

      def parse_house_number(address)
        return unless address[:address1]

        house = address[:address1].split(/\s+/).keep_if { |x| x =~ /\d/ }.join(' ')
        house.empty? ? nil : house
      end

      def add_card(post, card, action, options = {})
        post[:card] = {}
        if card.is_a?(NetworkTokenizationCreditCard)
          post[:card][:network_token] = card.number
          post[:card][:cryptogram] = card.payment_cryptogram
          post[:card][:eci] = card.eci
          post[:card][:bin] = options[:issuer_identification_number] if options[:issuer_identification_number]
        else
          post[:card][:number] = card.number
          post[:card][:cvv] = card.verification_value
        end

        if options[:stored_credential]
          # required for MC debit recurrent in BR 'USED'(subsecuence Payments) . 'FIRST' an inital payment
          post[:card][:stored_credential_usage] = (options[:stored_credential][:initial_transaction] ? 'FIRST' : 'USED')
          post[:card][:network_payment_reference] = options[:stored_credential][:network_transaction_id] if options[:stored_credential][:network_transaction_id]
          # used case of Network Token: 'CARD_ON_FILE', 'SUBSCRIPTION', 'UNSCHEDULED_CARD_ON_FILE'
          post[:card][:stored_credential_type] = fetch_stored_credential_type(options[:stored_credential])
        end

        post[:card][:holder_name] = card.name
        post[:card][:expiration_month] = card.month
        post[:card][:expiration_year] = card.year
        post[:card][:descriptor] = options[:dynamic_descriptor] if options[:dynamic_descriptor]
        post[:card][:capture] = (action == 'purchase')
        post[:card][:installments] = options[:installments] if options[:installments]
        post[:card][:installments_id] = options[:installments_id] if options[:installments_id]
        post[:card][:force_type] = options[:force_type].to_s.upcase if options[:force_type]
        post[:card][:save] = options[:save] if options[:save]
      end

      def fetch_stored_credential_type(stored_credential)
        if stored_credential[:reason_type] == 'unscheduled'
          stored_credential[:initiator] == 'merchant' ? 'UNSCHEDULED_CARD_ON_FILE' : 'CARD_ON_FILE'
        else
          'SUBSCRIPTION'
        end
      end

      def parse(body)
        JSON.parse(body)
      end

      def commit(action, parameters, options = {})
        three_ds_errors = validate_three_ds_params(parameters[:three_dsecure]) if parameters[:three_dsecure].present?
        return three_ds_errors if three_ds_errors

        url = url(action, parameters, options)
        post = post_data(action, parameters)
        begin
          raw = if %w(status orders).include?(action)
                  ssl_get(url, headers(nil, options))
                else
                  ssl_post(url, post, headers(post, options))
                end
          response = parse(raw)
        rescue ResponseError => e
          raw = e.response.body
          response = parse(raw)
        end

        Response.new(
          success_from(action, response),
          message_from(action, response),
          response,
          authorization: authorization_from(response),
          network_transaction_id: network_transaction_id_from(response),
          avs_result: AVSResult.new(code: response['some_avs_response_key']),
          cvv_result: CVVResult.new(response['some_cvv_response_key']),
          test: test?,
          error_code: error_code_from(action, response)
        )
      end

      # A refund may not be immediate, and return a status_code of 100, "Pending".
      # Since we aren't handling async notifications of eventual success,
      # we count 100 as a success.
      def success_from(action, response)
        return false unless response['status_code']

        if action == 'void'
          response['status_code'].to_s == '400' && response['status'] == 'CANCELLED'
        else
          %w[100 200 400 600 700].include? response['status_code'].to_s
        end
      end

      def message_from(action, response)
        response['status_detail'] || response['message']
      end

      def authorization_from(response)
        response['id']
      end

      def network_transaction_id_from(response)
        response.dig('card', 'network_tx_reference')
      end

      def error_code_from(action, response)
        return if success_from(action, response)

        code = response['status_code'] || response['code']
        code&.to_s
      end

      def url(action, parameters, options = {})
        "#{test? ? test_url : live_url}/#{endpoint(action, parameters, options)}/"
      end

      def endpoint(action, parameters, options)
        case action
        when 'purchase'
          'secure_payments'
        when 'authorize'
          'secure_payments'
        when 'refund'
          'refunds'
        when 'capture'
          'payments'
        when 'void'
          "payments/#{parameters[:authorization_id]}/cancel"
        when 'status'
          "payments/#{parameters[:payment_id]}/status"
        when 'orders'
          "orders/#{options[:order_id]}"
        end
      end

      def headers(post, options = {})
        timestamp = Time.now.utc.iso8601
        headers = {
          'Content-Type' => 'application/json',
          'X-Date' => timestamp,
          'X-Login' => @options[:login],
          'X-Trans-Key' => @options[:trans_key],
          'X-Version' => '2.1',
          'Authorization' => signature(post, timestamp)
        }
        headers['X-Idempotency-Key'] = options[:idempotency_key] if options[:idempotency_key]
        headers['X-Dlocal-Payment-Source'] = application_id if application_id
        headers
      end

      def signature(post, timestamp)
        content = "#{@options[:login]}#{timestamp}#{post}"
        digest = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), @options[:secret_key], content)
        "V2-HMAC-SHA256, Signature: #{digest}"
      end

      def post_data(action, parameters = {})
        parameters.to_json
      end

      def xid_or_ds_trans_id(three_d_secure)
        if three_d_secure[:version].to_f >= 2
          { ds_transaction_id: three_d_secure[:ds_transaction_id] }
        else
          { xid: three_d_secure[:xid] }
        end
      end

      def add_three_ds(post, options)
        return unless three_d_secure = options[:three_d_secure]

        post[:three_dsecure] = {
          mpi: true,
          three_dsecure_version: three_d_secure[:version],
          cavv: three_d_secure[:cavv],
          eci: three_d_secure[:eci],
          enrollment_response: formatted_enrollment(three_d_secure[:enrolled]),
          authentication_response: three_d_secure[:authentication_response_status]
        }.merge(xid_or_ds_trans_id(three_d_secure))
      end

      def validate_three_ds_params(three_ds)
        errors = {}
        supported_version = %w{1.0 2.0 2.1.0 2.2.0}.include?(three_ds[:three_dsecure_version])
        supported_enrollment = ['Y', 'N', 'U', nil].include?(three_ds[:enrollment_response])
        supported_auth_response = ['Y', 'N', 'U', nil].include?(three_ds[:authentication_response])

        errors[:three_ds_version] = 'ThreeDs version not supported' unless supported_version
        errors[:enrollment] = 'Enrollment value not supported' unless supported_enrollment
        errors[:auth_response] = 'Authentication response value not supported' unless supported_auth_response
        errors.compact!

        errors.present? ? Response.new(false, 'ThreeDs data is invalid', errors) : nil
      end

      def formatted_enrollment(val)
        case val
        when 'Y', 'N', 'U' then val
        when true, 'true' then 'Y'
        when false, 'false' then 'N'
        end
      end
    end
  end
end
