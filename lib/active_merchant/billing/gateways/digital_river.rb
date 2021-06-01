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
              check_customer_exists(options[:customer_vault_token])
            end
            return r unless r.responses.last.success?
            r.process do
              add_source_to_customer(payment_method, options[:customer_vault_token])
            end
          else
            r.process do
              create_customer(options)
            end
            return r unless r.responses.last.success?
            r.process do
              add_source_to_customer(payment_method, r.responses.last.authorization)
            end
          end
        end
      end

      def purchase(options)
        MultiResponse.new.tap do |r|
          r.process do
            create_order(options[:checkout_id])
          end

          return r unless r.responses.last.success?

          if order.state == 'accepted'
            r.process do
              create_fulfillment(order.id, items_from_order(order.items))
            end
            return r unless r.responses.last.success?
            r.process do
              get_charge_capture_id(order.id)
            end
          else
            return ActiveMerchant::Billing::Response.new(
              false,
              "Order not in 'accepted' state",
              {
                order_id: order.id,
                order_state: order.state
              },
              authorization: order.id
            )
          end
        end
      end

      private

      def create_fulfillment(order_id, items)
        fulfillment_params = { order_id: order_id, items: items }
        result = @digital_river_gateway.fulfillment.create(fulfillment_params)
        ActiveMerchant::Billing::Response.new(
          result.success?,
          message_from_result(result),
          {
            fulfillment_id: (result.value!.id if result.success?)
          }
        )
      end

      def get_charge_capture_id(order_id)
        charges = nil
        retry_until(2, "charge not found", 0.5) do
          charges = @digital_river_gateway.order.find(order_id).value!.charges
          charges&.first.present?
        end

        # for now we assume only one charge will be processed at one order
        captures = nil
        retry_until(2, "capture not found", 0.5) do
          captures = @digital_river_gateway.charge.find(charges.first.id).value!.captures
          captures&.first.present?
        end
        ActiveMerchant::Billing::Response.new(
          true,
          "OK",
          {
            order_id: order_id,
            charge_id: charges.first.id,
            capture_id: captures.first.id,
            source_id: charges.first.source_id
          },
          authorization: captures.first.id
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
          "email": options.dig(:email),
          "shipping": {
            "name": options.dig(:billing_address, :name),
            "organization": options.dig(:organization),
            "phone": options.dig(:phone),
            "address": {
              "line1": options.dig(:billing_address, :address1),
              "line2": options.dig(:billing_address, :address2),
              "city": options.dig(:billing_address, :city),
              "state": options.dig(:billing_address, :state),
              "postalCode": options.dig(:billing_address, :zip),
              "country": options.dig(:billing_address, :country),
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
        if @digital_river_gateway.customer.find(customer_vault_id).success?
          ActiveMerchant::Billing::Response.new(true, "Customer found", {exists: true}, authorization: customer_vault_id)
        else
          ActiveMerchant::Billing::Response.new(false, "Customer '#{customer_vault_id}' not found", {exists: false})
        end
      end

      def create_order(checkout_id)
        order_params = { checkout_id: checkout_id }
        @order = @digital_river_gateway.order.create(order_params)
        ActiveMerchant::Billing::Response.new(
          @order.success?,
          message_from_result(@order),
          {
            order_id: (@order.value!.id if @order.success?)
          }
        )
      end

      def order
        return unless @order

        @order.success? ? @order.value! : @order.failure
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

      def items_from_order(items)
        items.map { |item| { itemId: item.id, quantity: item.quantity.to_i, skuId: item.sku_id } }
      end
    end
  end
end
