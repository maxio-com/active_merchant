require 'digital_river'

module ActiveMerchant
  module Billing
    class DigitalRiverGateway < Gateway
      def initialize(options = {})
        requires!(options, :token)
        super

        token = options[:token]
        @digital_river_gateway = DigitalRiver::Gateway.new(token)
      end

      def store(payment_method, options = {})
        MultiResponse.new.tap do |r|
          if options[:customer_vault_token]
            r.process do
              customer_exists_response = check_customer_exists(options[:customer_vault_token])
              if customer_exists_response.params["exists"]
                add_source_to_customer(payment_method, payment_method[:customer_vault_token])
              end
            end
          else
            r.process do
              customer_id = create_customer(options).params["customer_vault_token"]
              add_source_to_customer(payment_method, customer_id) if customer_id
            end
          end
        end
      end

      def purchase(money, source_id, options)
        MultiResponse.new.tap do |r|
          res = nil
          r.process { res = @digital_river_gateway.order.find(options[:digital_river_order_id]) }
          if res.success?
            r.process { res = create_fulfillment(options[:digital_river_order_id], items_from_order(res.value!.items)) }
          end
          if res.success?
            r.process { get_charge_capture_id(options[:digital_river_order_id]) }
          end
        end
      end

      private

      def create_fulfillment(order_id, items)
        fulfillment_params = { orderId: order_id, items: items }
        result = @digital_river_gateway.fulfillment.create(fulfillment_params)
        ActiveMerchant::Billing::Response.new(
          result.success?,
          message_from_result(result),
          fulfillment_params(result)
        )
      end

      def get_charge_id(order_id)
        # for now we assume only one charge will be processed at one order
        order = @digital_river_gateway.order.find(order_id)
        capture = order.value!.charges.first.captures.first if order.success?
        ActiveMerchant::Billing::Response.new(
          order.success?,
          message_from_result(order),
          {
            order_id: (order.value!.id if order.success?),
            charge_id: (order.value!.charges.first.id if order.success?),
            source_id: (order.value!.charges.first.source_id if order.success?)
          },
          authorization: (capture.id)
        )
      end

      def add_source_to_customer(payment_method, customer_id)
        result = @digital_river_gateway
                   .customer
                   .attach_source(
                     customer_id,
                     payment_method
                   )
        ActiveMerchant::Billing::Response.new(
          result.success?,
          message_from_result(result),
          {
            customer_vault_token: (result.value!.customer_id if result.success?),
            payment_profile_token: (result.value!.id if result.success?)
          },
          authorization: (result.value!.customer_id if result.success?)
        )
      end

      def create_customer(options)
        params =
        {
          "email": options[:email],
          "shipping": {
            "name": options[:billing_address][:name],
            "organization": options[:organization],
            "phone": options[:phone],
            "address": {
              "line1": options[:billing_address][:address1],
              "line2": options[:billing_address][:address2],
              "city": options[:billing_address][:city],
              "state": options[:billing_address][:state],
              "postalCode": options[:billing_address][:zip],
              "country": options[:billing_address][:country],
            }
          }
        }
        result = @digital_river_gateway.customer.create(params)
        ActiveMerchant::Billing::Response.new(
          result.success?,
          message_from_result(result),
          {
            customer_vault_token: (result.value!.id if result.success?)
          },
          authorization: (result.value!.id if result.success?)
        )
      end

      def check_customer_exists(customer_vault_id)
        begin
          @digital_river_gateway.customer.find(customer_vault_id)
          ActiveMerchant::Billing::Response.new(true, "Customer found", {exists: true}, authorization: customer_vault_id)
        rescue Dry::Monads::Result::Failure
          ActiveMerchant::Billing::Response.new(true, "Customer not found", {exists: false})
        end
      end

      def headers(options)
        {
          "Authorization" => "Bearer #{options[:token]}",
          "Content-Type" => "application/json",
        }
      end

      def message_from_result(result)
        if result.success?
          "OK"
        elsif result.failure?
          result.failure[:errors].map { |e| "#{e[:message]} (#{e[:code]})" }.join(" ")
        end
      end

      def fulfillment_params(result)
        { fulfillment_id: result.value!.id } if result.success?
      end

      def items_from_order(items)
        items.map { |item| { itemId: item.id, quantity: item.quantity.to_i, skuId: item.sku_id } }
      end
    end
  end
end