require 'json'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class PaypalCommercePlatformGateway < Gateway
      self.test_url = 'https://api.sandbox.paypal.com'
      self.live_url = 'https://api.paypal.com'

      def initialize(options = {})
        requires!(options, :client_id, :secret, :bn_code)
        super(options)
      end

      def purchase(money, payment_method, options = {})
        post = {}
        add_order_id(post, money, options)
        add_amount(post[:purchase_units].first, money, options)
        add_payment_method(post, payment_method)

        commit(:post, '/v2/checkout/orders', post)
      end

      def store(payment_method, options = {})
        post = {}
        add_credit_card(post, payment_method, options)

        commit(:post, '/v2/vault/payment-tokens', post)
      end

      def refund(money, authorization, options = {})
        post = {}
        add_amount(post, money, options)

        commit(:post, "/v2/payments/captures/#{authorization}/refund", post)
      end

      def void(authorization, _options = {})
        post = {}

        commit(:post, "/v2/payments/captures/#{authorization}/refund", post)
      end


      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript
          .gsub(/(Authorization: Basic )\w+/, '\1[FILTERED]')
          .gsub(/(Authorization: Bearer )\w+/, '\1[FILTERED]')
          .gsub(/(access_token)\W+\w+/, '\1[FILTERED]')
          .gsub(/(number)\W+\d+/, '\1[FILTERED]')
          .gsub(/(security_code)\W+\d+/, '\1[FILTERED]')
      end

      private

      def add_credit_card(params, payment_method, options)
        params[:source] ||= {}
        params[:source][:card] = {
          type: format_card_brand(payment_method.brand),
          name: payment_method.name,
          number: payment_method.number,
          security_code: payment_method.verification_value,
          expiry: "#{payment_method.year}-#{format(payment_method.month, :two_digits)}",
        }

        if options[:billing_address].present?
          billing_address = options[:billing_address]
          address_line_1 = billing_address[:address1]
          address_line_1 += " #{billing_address[:address2]}" if billing_address[:address2].present?

          params[:source][:card][:billing_address] = {
            address_line_1: address_line_1,
            admin_area_2: billing_address[:city],
            admin_area_1: billing_address[:state],
            postal_code: billing_address[:zip],
            country_code: billing_address[:country]
          }

          params[:source][:card].delete(:billing_address) unless
            params[:source][:card][:billing_address].any? { |_, value| value.present? }
        end
      end

      def add_payment_method(post, payment_method)
        if payment_method.is_a?(String)
          add_payment_source_tokens(post, payment_method)
        end
      end

      def add_payment_source_tokens(post, payment_method)
        post[:payment_source] ||= {}
        post[:payment_source][:token] = {
          type: 'PAYMENT_METHOD_TOKEN',
          id: payment_method
        }
      end

      def add_order_id(post, money, options)
        post[:intent] = 'CAPTURE'
        post[:purchase_units] ||= {}
        post[:purchase_units] = [{
          reference_id: options[:order_id]
        }]
      end

      def add_amount(post, money, options)
        post[:amount] = {
          currency_code: options[:currency],
          value: amount(money)
        }
      end

      def access_token
        @access_token ||= begin
          path = '/v1/oauth2/token'
          body = URI.encode_www_form({ 'grant_type' => 'client_credentials' })

          headers = {
            'Authorization' => ('Basic ' + Base64.strict_encode64("#{@options[:client_id]}:#{@options[:secret]}")),
            'PayPal-Partner-Attribution-Id' => @options[:bn_code],
            'Content-Type' => 'application/x-www-form-urlencoded'
          }

          JSON.parse(ssl_request(:post, URI.join(base_url, path), body, headers))['access_token']
        end
      end

      def commit(http_method, path, params)
        url = URI.join(base_url, path)
        body = http_method == :delete ? nil : params.to_json

        response = JSON.parse(ssl_request(http_method, url, body, headers))
        success = success_from(response)

        Response.new(
          success,
          message_from(success, response),
          response,
          authorization: authorization_from(response, path),
          test: test?
        )
      end

      def format_card_brand(card_brand)
        {
          master: :mastercard,
          american_express: :amex
        }.fetch(card_brand.to_sym, card_brand).to_s
      end

      def success_from(response)
        ['CREATED', 'COMPLETED'].include?(response['status'])
      end

      def message_from(success, response)
        success ? 'Transaction approved' : response['message']
      end

      def authorization_from(response, path)
        case path
        when '/v2/vault/payment-tokens'
          response['id']
        when '/v2/checkout/orders'
          response['purchase_units'].first['payments']['captures'].first['id']
        end
      end

      def handle_response(response)
        case response.code.to_i
        when 200..499
          response.body
        else
          raise ResponseError.new(response)
        end
      end

      def base_url
        test? ? test_url : live_url
      end

      def headers
        {
          'Authorization' => ('Bearer ' + access_token),
          'PayPal-Partner-Attribution-Id' => @options[:bn_code],
          'Content-Type' => 'application/json'
        }
      end
    end
  end
end
