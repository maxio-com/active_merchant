require 'test_helper'
require 'digital_river'

class RemoteDigitalRiverTest < Test::Unit::TestCase
  def setup
    @gateway = DigitalRiverGateway.new(fixtures(:digital_river))
    @digital_river_backend = @gateway.instance_variable_get(:@digital_river_gateway)

    @customer = @digital_river_backend.customer.create(
      {
        "email": "test@example.com",
        "shipping": {
          "name": "John Doe",
          "organization": "Doe's",
          "phone": "1234",
          "address": {
            "line1": "Evergreen Avenue",
            "city": "Bloomfield",
            "state": "OH",
            "postal_code": "43040",
            "country": "US",
          }
        }
      }
    ).value!.id

    @store_options = {
      email: 'test@example.com',
      billing_address: {
        name: 'Joe Doe',
        organization: "Joe's",
        phone: '123',
        address1: 'Some Street',
        city: 'San Francisco',
        state: 'CA',
        zip: '61156',
        country: 'US'
      }
    }

    @sku = 'sku_14ce5d3f-b931-4fbc-8f87-88b82888f670' #sku created for the test account
  end

  def test_successful_store_without_customer_vault_token
    source = payment_source('4444222233331111')
    assert response = @gateway.store(source, @store_options)
    assert_success response
    assert_equal source, response.params["payment_profile_token"]
    assert_equal response.message, "OK"
    assert_equal response.params["customer_vault_token"], response.authorization
  end

  def test_successful_store_with_customer_vault_token
    source = payment_source('4444222233331111')
    assert response = @gateway.store(source, @store_options.merge(customer_vault_token: @customer))
    assert_success response
    assert_equal source, response.params["payment_profile_token"]
    assert_equal response.message, "OK"
    assert_equal response.params["customer_vault_token"], response.authorization
    assert_equal response.params["customer_vault_token"], @customer
  end

  def test_unsuccessful_store_when_customer_vault_token_not_exist
    source = payment_source('4444222233331111')
    assert response = @gateway.store(source, @store_options.merge(customer_vault_token: '123'))
    assert_failure response
    assert_equal "Customer '123' not found", response.message
  end

  def test_unsuccessful_store_when_customer_create_fails
    source = payment_source('4444222233331111')
    assert response = @gateway.store(source, { address: ""})
    assert_failure response
    assert_equal "A parameter is missing. (missing_parameter)", response.message
  end

  def test_unsuccessful_store_when_source_already_attached
    source = payment_source('4444222233331111')
    @gateway.store(source, @store_options)
    assert response = @gateway.store(source, @store_options)
    assert_failure response
    assert_equal "Source '#{source}' is attached to another customer. A source cannot be attached to more than one customer. (invalid_parameter)", response.message
  end

  def test_successful_purchase
    source = payment_source('4444222233331111')
    order = order_with_source(source)
    purchase_options = { order_id: order }

    assert response = @gateway.purchase(purchase_options)
    assert_success response
    assert_equal "OK", response.message
    assert_equal order, response.params["order_id"]
    assert_equal source, response.params["source_id"]
    assert response.params["charge_id"].present?
    assert response.params["capture_id"].present?
  end

  def test_unsuccessful_purchase_order_not_exist
    purchase_options = { order_id: '123' }
    assert response = @gateway.purchase(purchase_options)
    assert_failure response
    assert_equal "Order '123' not found. (not_found)", response.message
  end

  # For now we do not have a card to test this scenario
  # def test_purchase_with_order_in_pending_state
  #   source = payment_source('?')
  #   order = order_with_source(source)
  #   purchase_options = { order_id: order }
  #
  #   assert response = @gateway.purchase(purchase_options)
  #   assert_failure response
  #   assert_equal "Order not in 'accepted' state", response.message
  #   assert_equal order, response.params["order_id"]
  #   assert response.params["order_state"].present?
  # end

  def payment_source(number)
    @digital_river_backend.testing_source.create(
      {
        "type": 'creditCard',
        "owner": {
          "firstName": 'William',
          "lastName": 'Brown',
          "email": 'testing@example.com',
          "address": {
            "line1": '10380 Bren Road West',
            "city": 'Minnetonka',
            "state": 'MN',
            "country": 'US',
            "postalCode": '55343'
          }
        },
        "creditCard": {
          "number": number,
          "expirationMonth": 7,
          "expirationYear": 2027,
          "cvv": '415'
        }
      }
    ).value!.id
  end

  def order_with_source(source)
    checkout = @digital_river_backend.checkout.create(
      {
        "currency": 'USD',
        "taxInclusive": true,
        "customerId": @customer,
        "sourceId": source,
        "items": [
          {
            "skuId": @sku,
            "quantity": 1,
            "aggregatePrice": 249.99
          }
        ],
        "chargeType": "merchant_initiated"
      }
    ).value!.id
    @digital_river_backend.order.create(
      {
        'checkout_id' => checkout,
        'source_id' => source,
        'customer_id' => @customer,
        'items' => [{
          'sku_id' => @sku,
          'quantity' => 1,
          'price' => 9.99
        }]
      }
    ).value!.id
  end
end
