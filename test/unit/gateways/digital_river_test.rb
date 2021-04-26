require 'test_helper'
require 'digital_river'

class DigitalRiverTest < Test::Unit::TestCase
  def setup
    @gateway = DigitalRiverGateway.new(token: 'test')
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
    DigitalRiver::ApiClient
      .expects(:get)
      .with("/customers/123", anything)
      .returns(succcessful_customer_response)

    DigitalRiver::ApiClient
      .expects(:post)
      .with("/customers/123/sources/456", anything)
      .returns(successful_attach_source_response)

    assert response = @gateway.store('456', @store_options.merge(customer_vault_token: '123'))
    assert_success response
    assert_instance_of MultiResponse, response
    assert_equal "123", response.primary_response.params["customer_vault_token"]
    assert_equal "456", response.primary_response.params["payment_profile_token"]
    assert_equal response.message, "OK"
    assert_equal "123", response.authorization
  end

  def test_successful_store_without_customer_vault_token
    DigitalRiver::ApiClient
      .expects(:post)
      .with("/customers", anything)
      .returns(succcessful_customer_response)

    DigitalRiver::ApiClient
      .expects(:post)
      .with("/customers/123/sources/456", anything)
      .returns(successful_attach_source_response)

    assert response = @gateway.store('456', @store_options)
    assert_success response
    assert_instance_of MultiResponse, response
    assert_equal "123", response.primary_response.params["customer_vault_token"]
    assert_equal "456", response.primary_response.params["payment_profile_token"]
    assert_equal response.message, "OK"
    assert_equal "123", response.authorization
  end

  def test_unsuccessful_store_when_customer_vault_token_not_exist
    DigitalRiver::ApiClient
      .expects(:get)
      .with("/customers/123", anything)
      .returns(unsuccessful_customer_find_response)

    assert response = @gateway.store('456', @store_options.merge(customer_vault_token: '123'))
    assert_failure response
    assert_instance_of MultiResponse, response
    assert_equal "Customer '123' not found", response.primary_response.message
    assert_equal false, response.primary_response.params["exists"]
  end

  def test_unsuccessful_store_when_source_already_attached
    DigitalRiver::ApiClient
      .expects(:post)
      .with("/customers", anything)
      .returns(succcessful_customer_response)

    DigitalRiver::ApiClient
      .expects(:post)
      .with("/customers/123/sources/456", anything)
      .returns(source_already_attached_response)

    assert response = @gateway.store('456', @store_options)
    assert_failure response
    assert_equal "Source '456' is attached to another customer. A source cannot be attached to more than one customer. (invalid_parameter)", response.message
  end

  def succcessful_customer_response
    stub(
      success?: true,
      parsed_response: {
        id: "123",
        created_time: "2021-04-26T11:49:58Z",
        email: "test@example.com",
        shipping:
          {
            address: {
              line1: "Evergreen Avenue",
              city: "Bloomfield",
              postal_code: "43040",
              state: "OH",
              country: "US"
            },
            name: "John Doe",
            phone: "1234",
            organization: "Doe's"
          },
        ive_mode: false,
        enabled: true,
        request_to_be_forgotten: false,
        locale: "en_US",
        type: "individual"
      }
    )
  end

  def successful_attach_source_response
    stub(
      success?: true,
      parsed_response: {
        id: "456",
        customer_id:  "123",
        type: "creditCard",
        reusable: false,
        owner: {
          first_name: "William",
          last_name: "Brown",
          email: "testing@example.com",
          address: {
            line1: "10380 Bren Road West",
            city: "Minnetonka",
            state: "MN",
            country: "US",
            postal_code: "55343"
          }
        },
        state: "chargeable",
        created_time: "2021-04-26T11:50:38.983Z",
        updated_time: "2021-04-26T11:50:38.983Z",
        flow: "standard",
        credit_card: {
          brand: "Visa",
          expiration_month: 7,
          expiration_year: 2027,
          last_four_digits: "1111",
          payment_identifier: "00700"
        }
      }
    )
  end

  def unsuccessful_customer_find_response
    stub(
      success?: false,
      parsed_response: {
        type: "not_found",
        errors: [
          {
            code: "not_found",
            parameter: "id",
            message: "Customer '123' not found."
          }
        ]
      }
    )
  end

  def source_already_attached_response
    stub(
      success?: false,
      parsed_response: {
        type: "conflict",
        errors: [
          {
            code: "invalid_parameter",
            parameter: "sourceId",
            message: "Source '456' is attached to another customer. A source cannot be attached to more than one customer."
          }
        ]
      }
    )
  end
end
