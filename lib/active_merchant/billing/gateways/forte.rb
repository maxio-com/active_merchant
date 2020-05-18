require 'json'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class ForteGateway < Gateway
      include Empty

      self.test_url = 'https://sandbox.forte.net/api/v2'
      self.live_url = 'https://api.forte.net/v2'

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      self.homepage_url = 'https://www.forte.net'
      self.display_name = 'Forte'

      def initialize(options={})
        requires!(options, :api_key, :secret, :location_id)
        unless options.has_key?(:organization_id) || options.has_key?(:account_id)
          raise ArgumentError.new("Missing required parameter: organization_id or account_id")
        end
        super
      end

      def purchase(money, payment_method, options={})
        post = {}
        add_amount(post, money, options)
        add_invoice(post, options)
        add_payment_method(post, payment_method)
        add_billing_address(post, payment_method, options) unless payment_method.kind_of?(String)
        add_shipping_address(post, options) unless payment_method.kind_of?(String)
        post[:action] = 'sale'

        commit(:post, "/transactions", post)
      end

      def authorize(money, payment_method, options={})
        post = {}
        add_amount(post, money, options)
        add_invoice(post, options)
        add_payment_method(post, payment_method)
        add_billing_address(post, payment_method, options)
        add_shipping_address(post, options)
        post[:action] = 'authorize'

        commit(:post, "/transactions", post)
      end

      def capture(money, authorization, options={})
        post = {}
        post[:transaction_id] = transaction_id_from(authorization)
        post[:authorization_code] = authorization_code_from(authorization) || ''
        post[:action] = 'capture'

        commit(:put, "/transactions", post)
      end

      def credit(money, payment_method, options={})
        post = {}
        add_amount(post, money, options)
        add_invoice(post, options)
        add_payment_method(post, payment_method)
        add_billing_address(post, payment_method, options)
        post[:action] = 'disburse'

        commit(:post, "/transactions", post)
      end

      def refund(money, authorization, options={})
        post = {}
        add_amount(post, money, options)
        post[:original_transaction_id] = transaction_id_from(authorization)
        post[:authorization_code] = authorization_code_from(authorization)
        post[:action] = 'reverse'

        commit(:post, "/transactions", post)
      end

      def store(credit_card, options = {})
        post = {}
        add_customer(post, credit_card, options)
        add_customer_paymethod(post, credit_card)
        add_customer_billing_address(post, options)

        commit(:post, "/customers", post)
      end

      def unstore(identification, options = {})
        customer_token, paymethod_token = identification.split('|')

        if (customer_token && !paymethod_token)
          commit(:delete, "/customers/#{customer_token}", {})
        else
          commit(:delete, "/paymethods/#{paymethod_token}", {})
        end
      end

      def void(authorization, options={})
        post = {}
        post[:transaction_id] = transaction_id_from(authorization)
        post[:authorization_code] = authorization_code_from(authorization)
        post[:action] = 'void'

        commit(:put, "/transactions", post)
      end

      def verify(credit_card, options={})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript.
          gsub(%r((Authorization: Basic )\w+), '\1[FILTERED]').
          gsub(%r((account_number)\W+\d+), '\1[FILTERED]').
          gsub(%r((card_verification_value)\W+\d+), '\1[FILTERED]')
      end

      private

      def add_auth(post)
        post[:account_id] = "act_#{organization_id}"
        post[:location_id] = "loc_#{@options[:location_id]}"
      end

      def add_invoice(post, options)
        post[:order_number] = options[:order_id]
      end

      def add_amount(post, money, options)
        post[:authorization_amount] = amount(money)
      end

      def add_customer(post, payment_method, options)
        post[:first_name] = payment_method.first_name
        post[:last_name] = payment_method.last_name
      end

      def add_customer_paymethod(post, payment_method)
        post[:paymethod] = {}
        post[:paymethod][:card] = {}
        post[:paymethod][:card][:card_type] = format_card_brand(payment_method.brand)
        post[:paymethod][:card][:name_on_card] = payment_method.name
        post[:paymethod][:card][:account_number] = payment_method.number
        post[:paymethod][:card][:expire_month] = payment_method.month
        post[:paymethod][:card][:expire_year] = payment_method.year
        post[:paymethod][:card][:card_verification_value] = payment_method.verification_value
      end

      def add_customer_billing_address(post, options)
        post[:addresses] = []
        if address = options[:billing_address] || options[:address]
          billing_address = {}
          billing_address[:address_type] = "default_billing"
          billing_address[:physical_address] = {}
          billing_address[:physical_address][:street_line1] = address[:address1] if address[:address1]
          billing_address[:physical_address][:street_line2] = address[:address2] if address[:address2]
          billing_address[:physical_address][:postal_code] = address[:zip] if address[:zip]
          billing_address[:physical_address][:region] = address[:state] if address[:state]
          billing_address[:physical_address][:locality] = address[:city] if address[:city]
          billing_address[:email] = options[:email] if options[:email]
          post[:addresses] << billing_address
        end
      end

      def add_billing_address(post, payment, options)
        post[:billing_address] = {}
        if address = options[:billing_address] || options[:address]
          first_name, last_name = split_names(address[:name])
          post[:billing_address][:first_name] = first_name if first_name
          post[:billing_address][:last_name] = last_name if last_name
          post[:billing_address][:physical_address] = {}
          post[:billing_address][:physical_address][:street_line1] = address[:address1] if address[:address1]
          post[:billing_address][:physical_address][:street_line2] = address[:address2] if address[:address2]
          post[:billing_address][:physical_address][:postal_code] = address[:zip] if address[:zip]
          post[:billing_address][:physical_address][:region] = address[:state] if address[:state]
          post[:billing_address][:physical_address][:locality] = address[:city] if address[:city]
        end

        post[:billing_address][:first_name] = payment.first_name if empty?(post[:billing_address][:first_name]) && payment.first_name

        post[:billing_address][:last_name] = payment.last_name if empty?(post[:billing_address][:last_name]) && payment.last_name
      end

      def add_shipping_address(post, options)
        return unless options[:shipping_address]

        address = options[:shipping_address]

        post[:shipping_address] = {}
        first_name, last_name = split_names(address[:name])
        post[:shipping_address][:first_name] = first_name if first_name
        post[:shipping_address][:last_name] = last_name if last_name
        post[:shipping_address][:physical_address][:street_line1] = address[:address1] if address[:address1]
        post[:shipping_address][:physical_address][:street_line2] = address[:address2] if address[:address2]
        post[:shipping_address][:physical_address][:postal_code] = address[:zip] if address[:zip]
        post[:shipping_address][:physical_address][:region] = address[:state] if address[:state]
        post[:shipping_address][:physical_address][:locality] = address[:city] if address[:city]
      end

      def add_payment_method(post, payment_method)
        if payment_method.kind_of?(String)
          if payment_method.include?('|')
            customer_token, paymethod_token = payment_method.split('|')
            add_customer_token(post, customer_token)
            add_paymethod_token(post, paymethod_token)
          else
            add_customer_token(post, payment_method)
          end
        elsif payment_method.respond_to?(:brand)
          add_credit_card(post, payment_method)
        else
          add_echeck(post, payment_method)
        end
      end

      def add_echeck(post, payment)
        post[:echeck] = {}
        post[:echeck][:account_holder] = payment.name
        post[:echeck][:account_number] = payment.account_number
        post[:echeck][:routing_number] = payment.routing_number
        post[:echeck][:account_type] = payment.account_type
        post[:echeck][:check_number] = payment.number
        # TODO: make sec_code configurable in options hash
        # sec_code is temporarily hard-coded as "WEB" to fix remote test failure
        # see public issue https://github.com/activemerchant/active_merchant/issues/3612
        post[:echeck][:sec_code] = "WEB"
      end

      def add_credit_card(post, payment)
        post[:card] = {}
        post[:card][:card_type] = format_card_brand(payment.brand)
        post[:card][:name_on_card] = payment.name
        post[:card][:account_number] = payment.number
        post[:card][:expire_month] = payment.month
        post[:card][:expire_year] = payment.year
        post[:card][:card_verification_value] = payment.verification_value
      end

      def add_customer_token(post, payment_method)
        post[:customer_token] = payment_method
      end

      def add_paymethod_token(post, payment_method)
        post[:paymethod_token] = payment_method
      end

      def commit(type, path, parameters)
        add_auth(parameters)

        url = (test? ? test_url : live_url) + endpoint + path
        body = type == :delete ? nil : parameters.to_json
        response = parse(handle_resp(raw_ssl_request(type, url, body, headers)))

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response, parameters),
          avs_result: AVSResult.new(code: response['response']['avs_result']),
          cvv_result: CVVResult.new(response['response']['cvv_code']),
          test: test?
        )
      end

      def handle_resp(response)
        case response.code.to_i
        when 200..499
          response.body
        else
          raise ResponseError.new(response)
        end
      end

      def parse(response_body)
        JSON.parse(response_body)
      end

      def success_from(response)
        response['response']['response_code'] == 'A01' ||
          response['response']['response_desc'] == "Create Successful." ||
          response['response']['response_desc'] == "Delete Successful."
      end

      def message_from(response)
        response['response']['response_desc']
      end

      def authorization_from(response, parameters)
        if parameters[:action] == 'capture'
          [response['transaction_id'], response.dig('response', 'authorization_code'), parameters[:transaction_id], parameters[:authorization_code]].join('#')
        else
          [response['transaction_id'], response.dig('response', 'authorization_code')].join('#')
        end
      end

      def endpoint
          "/accounts/act_#{organization_id.strip}/locations/loc_#{@options[:location_id].strip}"
      end

      def headers
        {
          'Authorization' => ('Basic ' + Base64.strict_encode64("#{@options[:api_key]}:#{@options[:secret]}")),
          'X-Forte-Auth-Account-Id' => "act_#{organization_id}",
          'Content-Type' => 'application/json'
        }
      end

      def format_card_brand(card_brand)
        case card_brand
        when 'visa'
          return 'visa'
        when 'master'
          return 'mast'
        when 'american_express'
          return 'amex'
        when 'discover'
          return 'disc'
        end
      end

      def split_authorization(authorization)
        authorization.split('#')
      end

      def authorization_code_from(authorization)
        _, authorization_code, _, original_auth_authorization_code = split_authorization(authorization)
        original_auth_authorization_code.present? ? original_auth_authorization_code : authorization_code
      end

      def transaction_id_from(authorization)
        transaction_id, _, original_auth_transaction_id, _ = split_authorization(authorization)
        original_auth_transaction_id.present? ? original_auth_transaction_id : transaction_id
      end

      def organization_id
        @options[:organization_id] || @options[:account_id]
      end
    end
  end
end
