module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # Bogus Gateway
    class BogusGateway < Gateway
      AUTHORIZATION = '53433'

      AUTHORIZATION_EMV_SUCCESS = '8A023030'
      AUTHORIZATION_EMV_DECLINE = '8A023035'

      SUCCESS_MESSAGE = "Bogus Gateway: Forced success"
      FAILURE_MESSAGE = "Bogus Gateway: Forced failure"
      NUMBER_ERROR_MESSAGE = "Bogus Gateway: Use CreditCard number ending in 1 for success, 2 for exception and anything else for error"
      AMOUNT_ERROR_MESSAGE = "Bogus Gateway: Use amount ending in 00 for success, 05 for failure and anything else for exception"
      UNSTORE_ERROR_MESSAGE = "Bogus Gateway: Use trans_id ending in 1 for success, 2 for exception and anything else for error"
      CAPTURE_ERROR_MESSAGE = "Bogus Gateway: Use authorization number ending in 1 for exception, 2 for error and anything else for success"
      VOID_ERROR_MESSAGE = "Bogus Gateway: Use authorization number ending in 1 for exception, 2 for error and anything else for success"
      REFUND_ERROR_MESSAGE = "Bogus Gateway: Use trans_id number ending in 1 for exception, 2 for error and anything else for success"
      CHECK_ERROR_MESSAGE = "Bogus Gateway: Use bank account number ending in 1 for success, 2 for exception and anything else for error"
      STORE_ERROR_MESSAGE = 'Bogus Gateway: Card numbers ending in 3 always fail to store'.freeze
      LIVE_SITE_MESSAGE = 'Test Gateway: transactions always fail on live Sites. Connect a real gateway.'.freeze

      # Last four digits that fail like a real network error would (E1)
      NETWORK_ERROR_CARDS = {
        '0028' => Timeout::Error,
        '0036' => OpenSSL::SSL::SSLError,
        '0044' => Errno::ECONNRESET
      }.freeze

      self.supported_countries = []
      self.supported_cardtypes = [:bogus]
      self.homepage_url = 'http://example.com'
      self.display_name = 'Bogus'

      def authorize(money, paysource, options = {})
        params = { authorized_amount: amount(money), last4: last4(paysource) }
        return failure_response(LIVE_SITE_MESSAGE, params) if live_site?(options)

        if paysource.respond_to?(:emv?) && paysource.emv?
          authorize_emv(money, paysource, options)
        elsif paysource.is_a?(Check)
          authorize_swipe(money, paysource, options)
        else
          card_response(paysource, params)
        end
      end

      def purchase(money, paysource, options = {})
        params = { paid_amount: amount(money), last4: last4(paysource) }
        return failure_response(LIVE_SITE_MESSAGE, params) if live_site?(options)

        if paysource.respond_to?(:emv?) && paysource.emv?
          purchase_emv(money, paysource, options)
        elsif paysource.is_a?(Check) || paysource == AUTHORIZATION
          purchase_swipe(money, paysource, options)
        else
          card_response(paysource, params)
        end
      end

      def credit(money, paysource, options = {})
        if paysource.is_a?(String)
          ActiveMerchant.deprecated CREDIT_DEPRECATION_MESSAGE
          return refund(money, paysource, options)
        end
        return failure_response(LIVE_SITE_MESSAGE, paid_amount: amount(money)) if live_site?(options)

        money = amount(money)
        case normalize(paysource)
        when /1$/
          Response.new(true, SUCCESS_MESSAGE, {:paid_amount => money}, :test => true )
        when /2$/
          Response.new(false, FAILURE_MESSAGE, {:paid_amount => money, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error])
        else
          raise Error, error_message(paysource)
        end
      end

      def refund(money, _reference, options = {})
        params = { paid_amount: amount(money) }
        return failure_response(LIVE_SITE_MESSAGE, params) if live_site?(options)

        success_response(params)
      end

      def capture(money, _reference, options = {})
        params = { paid_amount: amount(money) }
        return failure_response(LIVE_SITE_MESSAGE, params) if live_site?(options)

        success_response(params)
      end

      def void(_reference, options = {})
        return failure_response(LIVE_SITE_MESSAGE) if live_site?(options)

        success_response
      end

      def verify(paysource, options = {})
        return failure_response(LIVE_SITE_MESSAGE, last4: last4(paysource)) if live_site?(options)
        return card_response(paysource, last4: last4(paysource)) unless paysource.is_a?(Check)

        case normalize(paysource)
        when /1$/
          Response.new(true, SUCCESS_MESSAGE, {:billingid => '1'}, :test => true, :authorization => AUTHORIZATION)
        when /2$/
          Response.new(false, FAILURE_MESSAGE, {:billingid => nil, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error])
        else
          raise Error, error_message(paysource)
        end
      end

      def store(paysource, options = {})
        return failure_response(LIVE_SITE_MESSAGE, last4: last4(paysource)) if live_site?(options)
        return store_card(paysource, options[:site_id]) unless paysource.is_a?(Check)

        case normalize(paysource)
        when /1$/
          Response.new(true, SUCCESS_MESSAGE, {:billingid => '1'}, :test => true, :authorization => AUTHORIZATION)
        when /2$/
          Response.new(false, FAILURE_MESSAGE, {:billingid => nil, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error])
        else
          raise Error, error_message(paysource)
        end
      end

      # Succeeds on live Sites too, so a merchant can remove test cards (E8)
      def unstore(_reference, _options = {})
        Response.new(true, SUCCESS_MESSAGE, {}, test: true)
      end

      private

      # Exactly true or false; a caller that omits it raises instead of charging a live Site (E4)
      def live_site?(options)
        requires!(options, [:live_site, true, false])
        options[:live_site]
      end

      def card_response(paysource, params)
        if (exception = NETWORK_ERROR_CARDS[last4(paysource)])
          message = NetworkConnectionRetries::DEFAULT_CONNECTION_ERRORS[exception]
          raise ActiveMerchant::ConnectionError.new(message, exception.new)
        end

        case normalize(paysource).to_s
        when /1$/ then success_response(params)
        when /2$/ then failure_response(FAILURE_MESSAGE, params)
        else raise Error, NUMBER_ERROR_MESSAGE
        end
      end

      def store_card(paysource, site_id)
        raise ArgumentError, 'Missing required parameter: site_id' if site_id.blank?
        raise Error, STORE_ERROR_MESSAGE if normalize(paysource).to_s.end_with?('3')

        token = "bogus_#{site_id}_#{SecureRandom.hex(4)}_#{last4(paysource)}"
        Response.new(true, SUCCESS_MESSAGE, { billingid: token, last4: last4(paysource) },
                     test: true, authorization: token)
      end

      def success_response(params = {})
        authorization = "bogus_txn_#{SecureRandom.hex(8)}"
        Response.new(true, SUCCESS_MESSAGE, params.merge(authorization: authorization),
                     test: true, authorization: authorization)
      end

      def failure_response(message, params = {})
        Response.new(false, message, params.merge(authorization: nil, error: message),
                     test: true, error_code: STANDARD_ERROR_CODE[:processing_error])
      end

      def last4(paysource)
        normalize(paysource).to_s[/.{0,4}\z/]
      end

      def authorize_emv(money, paysource, options = {})
        money = amount(money)
        case money
        when /00$/
          Response.new(true, SUCCESS_MESSAGE, {:authorized_amount => money}, :test => true, :authorization => AUTHORIZATION, :emv_authorization => AUTHORIZATION_EMV_SUCCESS)
        when /05$/
          Response.new(false, FAILURE_MESSAGE, {:authorized_amount => money, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error], :emv_authorization => AUTHORIZATION_EMV_DECLINE)
        else
          raise Error, error_message(paysource)
        end
      end

      def authorize_swipe(money, paysource, options = {})
        money = amount(money)
        case normalize(paysource)
        when /1$/
          Response.new(true, SUCCESS_MESSAGE, {:authorized_amount => money}, :test => true, :authorization => AUTHORIZATION )
        when /2$/
          Response.new(false, FAILURE_MESSAGE, {:authorized_amount => money, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error])
        else
          raise Error, error_message(paysource)
        end
      end

      def purchase_emv(money, paysource, options = {})
        money = amount(money)
        case money
        when /00$/
          Response.new(true, SUCCESS_MESSAGE, {:paid_amount => money}, :test => true, :authorization => AUTHORIZATION, :emv_authorization => AUTHORIZATION_EMV_SUCCESS)
        when /05$/
          Response.new(false, FAILURE_MESSAGE, {:paid_amount => money, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error], :emv_authorization => AUTHORIZATION_EMV_DECLINE)
        else
          raise Error, error_message(paysource)
        end
      end

      def purchase_swipe(money, paysource, options = {})
        money = amount(money)
        case normalize(paysource)
        when /1$/, AUTHORIZATION
          Response.new(true, SUCCESS_MESSAGE, {:paid_amount => money}, :test => true, :authorization => AUTHORIZATION)
        when /2$/
          Response.new(false, FAILURE_MESSAGE, {:paid_amount => money, :error => FAILURE_MESSAGE }, :test => true, :error_code => STANDARD_ERROR_CODE[:processing_error])
        else
          raise Error, error_message(paysource)
        end
      end

      def normalize(paysource)
        if paysource.respond_to?(:account_number) && (paysource.try(:number).blank? || paysource.number.blank?)
          paysource.account_number
        elsif paysource.respond_to?(:number)
          paysource.number
        else
          paysource.to_s
        end
      end

      def error_message(paysource)
        if paysource.respond_to?(:emv?) && paysource.emv?
          AMOUNT_ERROR_MESSAGE
        elsif paysource.respond_to?(:account_number)
          CHECK_ERROR_MESSAGE
        elsif paysource.respond_to?(:number)
          NUMBER_ERROR_MESSAGE
        end
      end
    end
  end
end
