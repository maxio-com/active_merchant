require 'json'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class GoCardlessGateway < ActiveMerchant::Billing::Gateway
      API_VERSION = '2015-07-06'.freeze

      self.test_url = 'https://api-sandbox.gocardless.com'
      self.live_url = 'https://api.gocardless.com'
      self.default_currency = 'EUR'

      def initialize(options = {})
        requires!(options, :access_token)
        super
      end

      def purchase(money, token, options = {})
        post = {
          payments: {
            amount: money,
            currency: options[:currency] || currency(money),
            description: options[:description],
            links: {
              mandate: token
            }
          }
        }

        commit('/payments', post, options)
      end

      def supports_scrubbing?
        false
      end

      private

      def test?
        @options[:access_token].start_with?('sandbox_')
      end

      def url
        test? ? test_url : live_url
      end

      def parse(response)
        JSON.parse(response)
      end

      def commit(action, params, options={})
        begin
          response = parse(ssl_post(
            (url + action),
            params.to_json,
            headers(options)
          ))
        rescue ResponseError => e
          response = parse(e.response.body)
        end

        return Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response, params),
          test: test?
        )
      rescue JSON::ParserError
        return unparsable_response(response)
      end

      def success_from(response)
        (!response['error'])
      end

      def message_from(response)
        (response['error'] ? response['error']['message'] : 'Success')
      end

      def authorization_from(response, params)
        response['payments']['id'] if response['payments']
      end

      def unparsable_response(raw_response)
        message = 'Invalid JSON response received from GoCardless. Please contact GoCardless support if you continue to receive this message.'
        message += " (The raw response returned by the API was #{raw_response.inspect})"
        Response.new(false, message)
      end

      def headers(options)
        {
          'Content-Type'       => 'application/json',
          'Accept'             => 'application/json',
          'User-Agent'         => "ActiveMerchantBindings/#{ActiveMerchant::VERSION}",
          'Authorization'      => "Bearer #{@options[:access_token]}",
          'GoCardless-Version' => API_VERSION
        }.tap do |h|
          h['Idempotency-Key'] = options[:order_id] if options[:order_id]
        end
      end
    end
  end
end
