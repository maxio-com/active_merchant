require 'test_helper'
require 'digital_river'

class DigitalRiverTest < Test::Unit::TestCase
  def setup
    @gateway = DigitalRiverGateway.new(:token => 'test')
    @backend_gateway = @gateway.instance_variable_get(:@digital_river_gateway)

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
  end

  def test_successful_store_with_customer_vault_token
    @gateway
      .expects(:check_customer_exists)
      .with("123")
      .returns(succcessful_customer_exists_response)
    @gateway
      .expects(:add_source_to_customer)
      .with("456", "123")
      .returns(successful_attach_source_response)

    assert response = @gateway.store('456', @store_options.merge(customer_vault_token: '123'))
    assert_success response
    assert_instance_of MultiResponse, response
    assert_equal "123", response.primary_response.params["customer_vault_token"]
    assert_equal "456", response.primary_response.params["payment_profile_token"]
  end

  def test_successful_store_with_no_customer_vault_token
    @gateway
      .expects(:create_customer)
      .with(@store_options)
      .returns(succcessful_customer_create_response)
    @gateway
      .expects(:add_source_to_customer)
      .with("456", "123")
      .returns(successful_attach_source_response)

    assert response = @gateway.store('456', @store_options)
    assert_success response
    assert_instance_of MultiResponse, response
    assert_equal "123", response.primary_response.params["customer_vault_token"]
    assert_equal "456", response.primary_response.params["payment_profile_token"]
  end

  def test_unsuccessful_store_when_customer_vault_token_not_exist
    @gateway
      .expects(:check_customer_exists)
      .with("123")
      .returns(unsuccessful_customer_create_response)

    assert response = @gateway.store('456', @store_options.merge(customer_vault_token: '123'))
    assert_failure response
    assert_instance_of MultiResponse, response
    assert_equal "Customer '123' not found", response.primary_response.message
    assert_equal false, response.primary_response.params["exists"]
    assert_equal "123", response.primary_response.authorization
  end

  def succcessful_customer_create_response
    ActiveMerchant::Billing::Response.new(
      true,
      "",
      {
        customer_vault_token: "123"
      },
      authorization: "123"
    )
  end

  def unsuccessful_customer_create_response
    ActiveMerchant::Billing::Response.new(
      false,
      "Customer '123' not found",
      {
        exists: false
      },
      authorization: "123"
    )
  end

  def succcessful_customer_exists_response
    ActiveMerchant::Billing::Response.new(true, "Customer found", {exists: true}, authorization: '123')
  end

  def successful_attach_source_response
    ActiveMerchant::Billing::Response.new(
      true,
      "",
      {
        customer_vault_token: "123",
        payment_profile_token: "456"
      },
      authorization: "123"
    )
  end
end
