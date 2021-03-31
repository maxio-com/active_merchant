require "square"
require "pry"

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class SquareOfficialGateway < Gateway
      self.test_url = "https://connect.squareupsandbox.com/v2"
      self.live_url = "https://connect.squareup.com/v2"

      self.supported_countries = %w[US CA GB AU JP]
      self.default_currency = "USD"
      self.supported_cardtypes = %i[visa master american_express discover jcb union_pay]
      self.money_format = :cents

      self.homepage_url = "https://squareup.com/"
      self.display_name = "Square Payments Gateway"

      CVC_CODE_TRANSLATOR = {
        "CVV_ACCEPTED" => "M",
        "CVV_REJECTED" => "N",
        "CVV_NOT_CHECKED" => "P"
      }.freeze

      AVS_CODE_TRANSLATOR = {
        "AVS_ACCEPTED" => "P", # 'P' => 'Postal code matches, but street address not verified.'
        "AVS_REJECTED" => "N", # 'N' => 'Street address and postal code do not match.'
        "AVS_NOT_CHECKED" => "I" # 'I' => 'Address not verified.'
      }.freeze

      STANDARD_ERROR_CODE_MAPPING = {
        "BAD_EXPIRATION" => STANDARD_ERROR_CODE[:invalid_expiry_date],
        "INVALID_ACCOUNT" => STANDARD_ERROR_CODE[:config_error],
        "CARDHOLDER_INSUFFICIENT_PERMISSIONS" => STANDARD_ERROR_CODE[:card_declined],
        "INSUFFICIENT_PERMISSIONS" => STANDARD_ERROR_CODE[:config_error],
        "INSUFFICIENT_FUNDS" => STANDARD_ERROR_CODE[:card_declined],
        "INVALID_LOCATION" => STANDARD_ERROR_CODE[:processing_error],
        "TRANSACTION_LIMIT" => STANDARD_ERROR_CODE[:card_declined],
        "CARD_EXPIRED" => STANDARD_ERROR_CODE[:expired_card],
        "CVV_FAILURE" => STANDARD_ERROR_CODE[:incorrect_cvc],
        "ADDRESS_VERIFICATION_FAILURE" => STANDARD_ERROR_CODE[:incorrect_address],
        "VOICE_FAILURE" => STANDARD_ERROR_CODE[:card_declined],
        "PAN_FAILURE" => STANDARD_ERROR_CODE[:incorrect_number],
        "EXPIRATION_FAILURE" => STANDARD_ERROR_CODE[:invalid_expiry_date],
        "INVALID_EXPIRATION" => STANDARD_ERROR_CODE[:invalid_expiry_date],
        "CARD_NOT_SUPPORTED" => STANDARD_ERROR_CODE[:processing_error],
        "INVALID_PIN" => STANDARD_ERROR_CODE[:incorrect_pin],
        "INVALID_POSTAL_CODE" => STANDARD_ERROR_CODE[:incorrect_zip],
        "CHIP_INSERTION_REQUIRED" => STANDARD_ERROR_CODE[:processing_error],
        "ALLOWABLE_PIN_TRIES_EXCEEDED" => STANDARD_ERROR_CODE[:card_declined],
        "MANUALLY_ENTERED_PAYMENT_NOT_SUPPORTED" => STANDARD_ERROR_CODE[:unsupported_feature],
        "PAYMENT_LIMIT_EXCEEDED" => STANDARD_ERROR_CODE[:processing_error],
        "GENERIC_DECLINE" => STANDARD_ERROR_CODE[:card_declined],
        "INVALID_FEES" => STANDARD_ERROR_CODE[:config_error],
        "GIFT_CARD_AVAILABLE_AMOUNT" => STANDARD_ERROR_CODE[:card_declined],
        "BAD_REQUEST" => STANDARD_ERROR_CODE[:processing_error]
      }.freeze

      def initialize(options = {})
        requires!(options, :access_token)
        @access_token = options[:access_token]
        super
      end

      def square_client
        @square_client ||= Square::Client.new(
          access_token: @access_token,
          environment: test? ? "sandbox" : "production"
        )
      end

      def purchase(money, payment, options = {})
        post = create_post_for_purchase(money, payment, options)

        add_descriptor(post, options)
        post[:autocomplete] = true

        commit(:payments, :create_payment, post)
      end

      def refund(money, identification, options = {})
        post = { payment_id: identification }

        add_idempotency_key(post, options)
        add_amount(post, money, options)

        post[:reason] = options[:reason] if options[:reason]

        commit(:refunds, :refund_payment, post)
      end

      def store(payment, options = {})
        MultiResponse.run(:first) do |r|
          if !(options[:customer_id])
            post = {}
            add_customer(post, options)

            r.process { commit(:customers, :create_customer, post) }

            options[:customer_id] = r.responses.last.params["customer"]["id"]
          end

          r.process do
            commit(:customers, :create_customer_card, { card_nonce: payment },
                   customer_id: options[:customer_id])
          end
        end
      end

      def delete_customer(identification)
        commit(:customers, :delete_customer_card, nil, customer_id: identification)
      end

      def delete_customer_card(customer_id, card_id)
        commit(:customers, :delete_customer_card, nil, customer_id: customer_id, card_id: card_id)
      end
      alias unstore delete_customer_card

      def update_customer(identification, options = {})
        post = {}
        add_customer(post, options)

        commit(:customers, :update_customer, post, customer_id: identification)
      end

      private

      def add_idempotency_key(post, options)
        post[:idempotency_key] = options[:idempotency_key] || generate_unique_id
      end

      def add_amount(post, money, options)
        currency = options[:currency] || currency(money)
        post[:amount_money] = {
          amount: localized_amount(money, currency).to_i,
          currency: currency.upcase
        }
      end

      def add_descriptor(post, options)
        return unless options[:descriptor]

        post[:statement_description_identifier] = options[:descriptor]
      end

      def create_post_for_purchase(money, payment, options)
        post = {}

        post[:source_id] = payment
        post[:customer_id] = options[:customer] unless options[:customer].nil? || options[:customer].blank?

        add_idempotency_key(post, options)
        add_amount(post, money, options)

        post
      end

      def add_customer(post, options)
        first_name = options[:billing_address][:name].split(" ")[0]
        if options[:billing_address][:name].split(" ").length > 1
          last_name = options[:billing_address][:name].split(" ")[1]
        end

        post[:email_address] = options[:email] || nil
        post[:phone_number] = options[:billing_address] ? options[:billing_address][:phone] : nil
        post[:given_name] = first_name
        post[:family_name] = last_name

        post[:address] = {}
        post[:address][:address_line_1] = options[:billing_address] ? options[:billing_address][:address1] : nil
        post[:address][:address_line_2] = options[:billing_address] ? options[:billing_address][:address2] : nil
        post[:address][:locality] = options[:billing_address] ? options[:billing_address][:city] : nil
        post[:address][:administrative_district_level_1] =
          options[:billing_address] ? options[:billing_address][:state] : nil
        post[:address][:administrative_district_level_2] =
          options[:billing_address] ? options[:billing_address][:country] : nil
        post[:address][:country] = options[:billing_address] ? options[:billing_address][:country] : nil
        post[:address][:postal_code] = options[:billing_address] ? options[:billing_address][:zip] : nil
      end

      def sdk_request(api_name, method, body, params = {})
        parameters = body ? { body: body }.merge(params) : params

        raw_response = square_client.send(api_name).send(method, parameters)

        parse(raw_response)
      end

      def commit(api_name, method, body, params = {})
        response = sdk_request(api_name, method, body, params)
        success = success_from(response)

        card = card_from_response(response)

        avs_code = AVS_CODE_TRANSLATOR[card["avs_status"]]
        cvc_code = CVC_CODE_TRANSLATOR[card["cvv_status"]]

        Response.new(
          success,
          message_from(success, response),
          response,
          authorization: authorization_from(success, method, response),
          avs_result: success ? AVSResult.new(code: avs_code) : nil,
          cvv_result: success ? CVVResult.new(cvc_code) : nil,
          error_code: success ? nil : error_code_from(response),
          test: test?
        )
      end

      def card_from_response(response)
        return {} unless response["payment"]

        response["payment"]["card_details"] || {}
      end

      def success_from(response)
        !response.key?("errors")
      end

      def message_from(success, response)
        success ? "Transaction approved" : response["errors"][0]["detail"]
      end

      def authorization_from(success, method, response)
        return nil unless success

        case method
        when :create_customer, :update_customer
          response["customer"]["id"]
        when :create_customer_card
          response["card"]["id"]
        when :create_payment
          response["payment"]["id"]
        when :refund_payment
          response["refund"]["id"]
        when :delete_customer, :delete_customer_card
          {}
        end
      end

      def error_code_from(response)
        return nil unless response["errors"]

        code = response["errors"][0]["code"]
        STANDARD_ERROR_CODE_MAPPING[code] || STANDARD_ERROR_CODE[:processing_error]
      end

      def parse(raw_response)
        raw_response.body.to_h.with_indifferent_access
      end
    end
  end
end
