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
  end

  def test_successful_purchase_with_token
    response = @gateway.purchase(@amount, @token, @options)
    assert_success response
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, @declined_token, @options)
    assert_failure response
  end

  def test_invalid_login
    gateway = GoCardlessGateway.new(access_token: '')
    response = gateway.purchase(@amount, @token, @options)
    assert_failure response
  end
end
