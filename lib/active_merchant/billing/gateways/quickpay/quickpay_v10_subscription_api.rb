require 'json'
require 'active_merchant/billing/gateways/quickpay/quickpay_v10'
require 'active_merchant/billing/gateways/quickpay/quickpay_common'

module ActiveMerchant
  module Billing
    class QuickpayV10SubscriptionApiGateway < QuickpayV10Gateway
      def purchase(money, subscription_id, options = {})
        post ={}
        add_autocapture(post, true) # or false?
        add_order_id(post, options)
        add_amount(post, money, options)
        commit(synchronized_path("/subscriptions/#{subscription_id}/recurring"), post)
      end
    end
  end
end
