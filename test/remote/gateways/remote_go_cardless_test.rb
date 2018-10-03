require 'test_helper'

class RemoteWepayTest < Test::Unit::TestCase
  def setup
    @gateway = GoCardlessGateway.new(fixtures(:go_cardless))

    @amount = 1000
    @token = 'MD0004490FQE1D'
    @declined_token = 'MD0002390FQE1D'

    @options = {
      order_id: "doj-#{Time.now.to_i}",
      description: "John Doe - gold: Signup payment",
      currency: "EUR"
    }

    @customer_attributes = { 'email' => 'foo@bar.com', 'first_name' => 'John', 'last_name' => 'Doe' }
    @store_options = { billing_address: { country: 'FR' } }
    @bank_account = OpenStruct.new(iban: 'FR1420041010050500013M02606', first_name: 'John', last_name: 'Doe')
  end

  def test_successful_purchase_with_token
    response = @gateway.purchase(@amount, @token, @options)
    assert_success response
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, @declined_token, @options)
    assert_failure response
  end

  def test_purchase_invalid_login
    gateway = GoCardlessGateway.new(access_token: '')
    response = gateway.purchase(@amount, @token, @options)
    assert_failure response
  end

  def test_failed_store_invalid_customer_attrs
    invalid_customer_attributes = { 'email' => '', 'first_name' => 'John', 'last_name' => 'Doe' }

    response = @gateway.store(invalid_customer_attributes, @bank_account, @store_options)

    assert_failure response
  end

  def test_successful_store
    response = @gateway.store(@customer_attributes, @bank_account, @store_options)

    assert_success response
  end

  def test_store_invalid_login
    gateway = GoCardlessGateway.new(access_token: '')

    response = gateway.store(@customer_attributes, @bank_account, @store_options)

    assert_failure response
  end
end
