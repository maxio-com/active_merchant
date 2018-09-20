require 'test_helper'

class GoCardlessTest < Test::Unit::TestCase
  def setup
    @gateway = GoCardlessGateway.new(:access_token => 'sandbox_example')
    @amount = 1000
    @token = 'MD0004471PDN9N'
    @options = {
      order_id: "doj-2018091812403467",
      description: "John Doe - gold: Signup payment",
      currency: "EUR"
    }
  end

  def test_successful_purchase_with_token
    @gateway.expects(:ssl_request).returns(successful_purchase_response)

    assert response = @gateway.purchase(@amount, @token, @options)
    assert_instance_of Response, response
    assert_success response

    assert response.test?
  end

  def test_appropriate_purchase_amount
    @gateway.expects(:ssl_request).returns(successful_purchase_response)

    response = @gateway.purchase(@amount, @token, @options)
    assert_instance_of Response, response
    assert_success response

    assert_equal 1000, response.params['payments']['amount']
  end

  # Place raw successful response from gateway here
  def successful_purchase_response
    <<-RESPONSE
{
  "payments": {
    "id": "PM000BW9DTN7Q7",
    "created_at": "2018-09-18T12:45:18.664Z",
    "charge_date": "2018-09-21",
    "amount": 1000,
    "description": "John Doe - gold: Signup payment",
    "currency": "EUR",
    "status": "pending_submission",
    "amount_refunded": 0,
    "metadata": {},
    "links": {
      "mandate": "MD0004471PDN9N",
      "creditor": "CR00005PHGZZE7"
    }
  }
}
    RESPONSE
  end
end
