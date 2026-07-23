require File.dirname(__FILE__) + '/stripe'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # SetupIntent-based Stripe integration for US ACH (us_bank_account).
    #
    # Stripe is sunsetting the legacy Charges + Sources/Tokens API. US ACH moves to the
    # us_bank_account PaymentMethod + SetupIntent + PaymentIntent flow. This subclass pins the
    # modern Stripe API version independently of the legacy StripeGateway (which stays on its old
    # pinned version) and implements the ACH-specific store/purchase/refund/detach against the
    # modern API, reusing the parent's request/response machinery.
    #
    # Legacy ACH semantics are preserved: a `processing` PaymentIntent is treated as success
    # (see StripeGateway#success_response?), verification is microdeposit-based, and the bank
    # account holder type is mapped the same way (personal -> individual, business -> company).
    class StripeAchSetupIntentsGateway < StripeGateway
      SETUP_INTENTS_API_VERSION = "2026-05-27.dahlia".freeze
      PAYMENT_METHOD_TYPE = "us_bank_account".freeze

      self.display_name = "Stripe SetupIntents"

      # Creates a us_bank_account PaymentMethod on a (possibly new) Stripe customer and confirms a
      # SetupIntent with microdeposit verification plus an ACH mandate. Returns a response whose
      # authorization carries the customer id (cus_*) so the vault token stays cus_*; pm_*/seti_*
      # are never surfaced as the vault token.
      def store(payment, options = {})
        unless payment.is_a?(Check)
          return Response.new(false, "StripeAchSetupIntentsGateway only supports bank account (ACH) payment methods")
        end

        payment_method_response = create_payment_method(payment, options)
        return payment_method_response unless payment_method_response.success?

        payment_method_id = payment_method_response.authorization

        if options[:customer]
          store_on_existing_customer(options[:customer], payment_method_id, options)
        else
          store_on_new_customer(payment_method_id, options)
        end
      end

      # Charges a stored us_bank_account PaymentMethod off-session via a PaymentIntent. A
      # `processing` ACH PaymentIntent counts as success (StripeGateway#success_response?), which
      # preserves the legacy instant-confirm behaviour.
      def purchase(money, _payment, options = {})
        post = {}
        add_amount(post, money, options, true)
        post[:customer] = options[:customer]
        post[:payment_method] = us_bank_account_payment_method_for_customer(options[:customer])
        post[:payment_method_types] = [PAYMENT_METHOD_TYPE]
        post[:off_session] = true
        post[:confirm] = true
        post[:description] = options[:description] if options[:description]
        post[:statement_descriptor_suffix] = options[:statement_descriptor_suffix] if options[:statement_descriptor_suffix]
        add_metadata(post, options)
        add_application_fee(post, options)
        add_destination(post, options)

        commit(:post, "payment_intents", post, options)
      end

      # Refunds a us_bank_account PaymentIntent on the modern API. The modern PaymentIntent exposes
      # `latest_charge` rather than the legacy `charges.data` shape, so we refund by `payment_intent`
      # directly instead of resolving a charge id (do not reuse StripeGateway#payment_intent_id_to_charge_id).
      def refund(money, identification, options = {})
        post = { payment_intent: identification }
        add_amount(post, money, options)
        post[:refund_application_fee] = true if options[:refund_application_fee]
        post[:reverse_transfer] = options[:reverse_transfer] if options[:reverse_transfer]
        post[:metadata] = options[:metadata] if options[:metadata]

        commit(:post, "refunds", post, options)
      end

      # Fully refunds a us_bank_account PaymentIntent. Conduit routes full refunds through #void
      # before #refund; the legacy StripeGateway#void resolves a charge id via the old `charges.data`
      # shape, so we override to refund the whole PaymentIntent on the modern API instead.
      def void(identification, options = {})
        commit(:post, "refunds", { payment_intent: identification }, options)
      end

      # Detaches the customer's us_bank_account PaymentMethod(s). The legacy StripeGateway#unstore
      # deletes a card source (customers/{id}/cards/{id}), which does not apply to PaymentMethod-based
      # us_bank_account profiles.
      def unstore(identification, options = {}, _deprecated_options = {})
        customer_id = identification.to_s.split("|").first
        payment_methods = list_us_bank_account_payment_methods(customer_id)
        return Response.new(true, "No us_bank_account payment method to detach") if payment_methods.empty?

        MultiResponse.run(:first) do |r|
          payment_methods.each do |payment_method|
            r.process { commit(:post, "payment_methods/#{CGI.escape(payment_method["id"])}/detach", {}, options) }
          end
        end
      end

      private

      # On the modern API a created customer has no inline `sources` list (the Sources API is gone),
      # so the parent's authorization_from — which dereferences response["sources"]["data"] for the
      # "customers" endpoint — would raise. The vault token is simply the customer id (cus_*).
      def authorization_from(success, url, method, response)
        return response["id"] if success && url == "customers"

        super
      end

      def api_version(options = {})
        options[:stripe_api_version] || options[:version] || @options[:version] || SETUP_INTENTS_API_VERSION
      end

      def create_payment_method(bank_account, options)
        post = {
          type: PAYMENT_METHOD_TYPE,
          us_bank_account: {
            account_number: bank_account.account_number,
            routing_number: bank_account.routing_number,
            account_holder_type: BANK_ACCOUNT_HOLDER_TYPE_MAPPING[bank_account.account_holder_type],
          },
          billing_details: {
            name: bank_account.name,
            email: options[:email],
          },
        }
        post[:us_bank_account][:account_type] = bank_account.account_type if bank_account.account_type.present?
        add_billing_address(post, options)

        build_id_response(api_request(:post, "payment_methods", post, options))
      end

      def store_on_existing_customer(customer_id, payment_method_id, options)
        MultiResponse.run(:first) do |r|
          r.process { setup_intent(customer_id, payment_method_id, options) }
          if options[:set_default] && r.success?
            r.process { set_default_payment_method(customer_id, payment_method_id, options) }
          end
        end
      end

      def store_on_new_customer(payment_method_id, options)
        customer_post = {}
        customer_post[:description] = options[:description] if options[:description]
        customer_post[:email] = options[:email] if options[:email]

        MultiResponse.run(:first) do |r|
          r.process { commit(:post, "customers", customer_post, options) }
          customer_id = r.responses.last.authorization.to_s.split("|").first if r.success?
          r.process { setup_intent(customer_id, payment_method_id, options) }
          if options[:set_default] && r.success?
            r.process { set_default_payment_method(customer_id, payment_method_id, options) }
          end
        end
      end

      def setup_intent(customer_id, payment_method_id, options)
        post = {
          customer: customer_id,
          payment_method: payment_method_id,
          payment_method_types: [PAYMENT_METHOD_TYPE],
          confirm: true,
          payment_method_options: {
            us_bank_account: { verification_method: "microdeposits" }
          },
          mandate_data: { customer_acceptance: customer_acceptance(options) }
        }

        build_id_response(api_request(:post, "setup_intents", post, options))
      end

      def set_default_payment_method(customer_id, payment_method_id, options)
        commit(:post, "customers/#{CGI.escape(customer_id)}",
               { invoice_settings: { default_payment_method: payment_method_id } }, options)
      end

      # Online acceptance requires a real IP + user agent (a browser-originated mandate). When those
      # are absent (an API/server-side flow) we fall back to offline acceptance rather than sending
      # an online mandate with blank evidence. The explicit "api" channel always forces offline.
      def customer_acceptance(options)
        ip_address = options.dig(:device_data, :ip)
        user_agent = options.dig(:device_data, :user_agent)

        if options[:channel] != "api" && ip_address.present? && user_agent.present?
          { type: "online", online: { ip_address: ip_address, user_agent: user_agent } }
        else
          { type: "offline" }
        end
      end

      # Resolves the customer's us_bank_account PaymentMethod for an off-session charge. Prefers the
      # customer's default payment method only when it is itself a us_bank_account; otherwise falls
      # back to the single listed us_bank_account PM. Raises on ambiguity or absence rather than
      # silently charging the wrong method.
      def us_bank_account_payment_method_for_customer(customer)
        # Only modern PaymentMethods (pm_*) are valid as a PaymentIntent payment_method. Stripe can
        # list legacy bank-account sources here with their original ba_* id; those must not be used.
        payment_method_ids = list_us_bank_account_payment_methods(customer)
          .map { |pm| pm["id"] }
          .select { |id| id.to_s.start_with?("pm_") }

        return payment_method_ids.first if payment_method_ids.size == 1

        if payment_method_ids.size > 1
          # Disambiguate by the customer's default payment method, but only when the default is
          # itself one of the us_bank_account methods (it could be a card).
          default = customer_default_payment_method(customer)
          return default if default && payment_method_ids.include?(default)

          raise StripeCustomerManyPaymentMethodWithoutDefault,
                "Customer has more than one us_bank_account payment method but no default one."
        end

        raise RuntimeError, "Customer has no us_bank_account payment method."
      end

      def list_us_bank_account_payment_methods(customer)
        r = commit(:get, "payment_methods?customer=#{customer}&type=#{PAYMENT_METHOD_TYPE}", nil, options)

        raise StripeCustomerDoesNotExist, r.message if !r.success? && r.message.to_s.include?("No such customer:")
        raise RuntimeError, r.message unless r.success?

        Array(r.params["data"])
      end

      def customer_default_payment_method(customer)
        r = commit(:get, "customers/#{customer}", nil, options)
        r.params.dig("invoice_settings", "default_payment_method")
      end

      def add_billing_address(post, options)
        return unless (address = options[:billing_address] || options[:address])

        post[:billing_details][:address] = {}
        post[:billing_details][:address][:line1] = address[:address1] if address[:address1]
        post[:billing_details][:address][:line2] = address[:address2] if address[:address2]
        post[:billing_details][:address][:country] = address[:country] if address[:country]
        post[:billing_details][:address][:postal_code] = address[:zip] if address[:zip]
        post[:billing_details][:address][:state] = address[:state] if address[:state]
        post[:billing_details][:address][:city] = address[:city] if address[:city]
      end

      def build_id_response(response)
        success = response["error"].nil?

        if success && response["id"]
          Response.new(true, nil, response, authorization: response["id"])
        else
          Response.new(false, response.dig("error", "message"))
        end
      end
    end
  end
end
