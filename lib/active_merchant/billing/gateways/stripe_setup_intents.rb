require File.dirname(__FILE__) + '/stripe'

module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    # Scaffold for the SetupIntent-based Stripe ACH integration.
    #
    # Stripe is sunsetting the legacy Charges + Sources/Tokens API. US ACH is
    # moving to the us_bank_account PaymentMethod + SetupIntent + PaymentIntent
    # flow. This subclass exists so the modern Stripe API version can be pinned
    # independently of the legacy StripeGateway, which stays on its old pinned
    # version. The us_bank_account store/purchase/refund logic lands in a
    # follow-up ticket; the transaction methods raise until then so the new
    # gateway can never silently fall back to the legacy charge behaviour.
    class StripeSetupIntentsGateway < StripeGateway
      SETUP_INTENTS_API_VERSION = "2026-05-27.dahlia".freeze

      self.display_name = "Stripe SetupIntents"

      def store(_payment, _options = {})
        raise NotImplementedError, "StripeSetupIntentsGateway#store is not implemented yet (scaffold)"
      end

      def purchase(_money, _payment, _options = {})
        raise NotImplementedError, "StripeSetupIntentsGateway#purchase is not implemented yet (scaffold)"
      end

      def refund(_money, _identification, _options = {})
        raise NotImplementedError, "StripeSetupIntentsGateway#refund is not implemented yet (scaffold)"
      end

      private

      def api_version(options = {})
        options[:stripe_api_version] || options[:version] || @options[:version] || SETUP_INTENTS_API_VERSION
      end
    end
  end
end
