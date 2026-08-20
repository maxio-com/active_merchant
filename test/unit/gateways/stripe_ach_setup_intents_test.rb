require 'test_helper'

class StripeAchSetupIntentsTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = StripeAchSetupIntentsGateway.new(:login => 'login')

    @amount = 400
    @refund_amount = 200

    @check = check({
      bank_name: "STRIPE TEST BANK",
      account_number: "000123456789",
      routing_number: "110000000",
      account_holder_type: "personal",
      account_type: "checking",
    })

    @options = {
      billing_address: address,
      email: "buyer@example.com",
      currency: "USD",
    }
  end

  # --- scaffold guarantees (API version isolation) -------------------------------------------

  def test_inherits_from_stripe_gateway
    assert_kind_of StripeGateway, @gateway
  end

  def test_pins_modern_api_version_in_request_headers
    headers = @gateway.send(:headers)

    assert_equal StripeAchSetupIntentsGateway::SETUP_INTENTS_API_VERSION, headers["Stripe-Version"]
    assert_equal "2026-05-27.dahlia", headers["Stripe-Version"]
  end

  def test_legacy_stripe_gateway_version_is_unchanged
    legacy_headers = StripeGateway.new(:login => 'login').send(:headers)

    assert_equal "2015-04-07", legacy_headers["Stripe-Version"]
  end

  def test_explicit_version_option_still_overrides_the_pinned_default
    headers = @gateway.send(:headers, :version => "2020-08-27")

    assert_equal "2020-08-27", headers["Stripe-Version"]
  end

  # --- store ---------------------------------------------------------------------------------

  def test_store_rejects_non_bank_account_payment
    response = @gateway.store(credit_card, @options)

    assert_failure response
    assert_match(/only supports bank account/, response.message)
  end

  def test_store_creates_us_bank_account_pm_and_setup_intent_on_new_customer
    stub_pm = stub_request_for("payment_methods", successful_payment_method_response)
    stub_customer = stub_request_for("customers", successful_new_customer_response)
    stub_setup_intent = stub_request_for("setup_intents", successful_setup_intent_response)

    expect_ssl_for("/v1/payment_methods", stub_pm)
    expect_ssl_for("/v1/customers", stub_customer)
    expect_ssl_for("/v1/setup_intents", stub_setup_intent)

    response = @gateway.store(@check, @options)

    assert_success response
    # vault token is the customer id, never pm_*/seti_*
    assert_equal "cus_NEWACH123", response.authorization.split("|").first
  end

  def test_store_creates_payment_method_with_us_bank_account_fields_and_mapped_holder_type
    @gateway.expects(:ssl_request).with do |_method, endpoint, post, _headers|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods") &&
        post.include?("type=us_bank_account") &&
        post.include?("us_bank_account[account_number]=000123456789") &&
        post.include?("us_bank_account[routing_number]=110000000") &&
        post.include?("us_bank_account[account_holder_type]=individual") && # personal -> individual
        post.include?("us_bank_account[account_type]=checking")
    end.returns(successful_payment_method_response)
    @gateway.stubs(:ssl_request).with do |_method, endpoint, _post, _headers|
      endpoint.start_with?("https://api.stripe.com/v1/customers")
    end.returns(successful_new_customer_response)
    @gateway.stubs(:ssl_request).with do |_method, endpoint, _post, _headers|
      endpoint.start_with?("https://api.stripe.com/v1/setup_intents")
    end.returns(successful_setup_intent_response)

    assert_success @gateway.store(@check, @options)
  end

  def test_store_uses_online_mandate_for_browser_channel
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods")
    end.returns(successful_payment_method_response)
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/customers")
    end.returns(successful_new_customer_response)
    @gateway.expects(:ssl_request).with do |_m, endpoint, post, _h|
      endpoint.start_with?("https://api.stripe.com/v1/setup_intents") &&
        post.include?("mandate_data[customer_acceptance][type]=online") &&
        post.include?("payment_method_options[us_bank_account][verification_method]=microdeposits")
    end.returns(successful_setup_intent_response)

    options = @options.merge(channel: "chargify_js", device_data: { ip: "1.2.3.4", user_agent: "UA" })
    assert_success @gateway.store(@check, options)
  end

  def test_store_uses_offline_mandate_for_api_channel
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods")
    end.returns(successful_payment_method_response)
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/customers")
    end.returns(successful_new_customer_response)
    @gateway.expects(:ssl_request).with do |_m, endpoint, post, _h|
      endpoint.start_with?("https://api.stripe.com/v1/setup_intents") &&
        post.include?("mandate_data[customer_acceptance][type]=offline")
    end.returns(successful_setup_intent_response)

    assert_success @gateway.store(@check, @options.merge(channel: "api"))
  end

  # --- purchase ------------------------------------------------------------------------------

  def test_purchase_creates_off_session_payment_intent_with_resolved_bank_pm
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_single_bank_account)
    @gateway.expects(:ssl_request).with do |_m, endpoint, post, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_intents") &&
        post.include?("off_session=true") &&
        post.include?("confirm=true") &&
        post.include?("payment_method=pm_bank123") &&
        post.include?("payment_method_types[0]=us_bank_account")
    end.returns(successful_payment_intent_response("succeeded"))

    response = @gateway.purchase(@amount, nil, @options.merge(customer: "cus_ACH"))

    assert_success response
    assert_equal "pi_ach123", response.authorization
  end

  def test_purchase_treats_processing_payment_intent_as_success
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_single_bank_account)
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_intents")
    end.returns(successful_payment_intent_response("processing"))

    assert_success @gateway.purchase(@amount, nil, @options.merge(customer: "cus_ACH"))
  end

  def test_purchase_raises_when_customer_has_no_us_bank_account_pm
    @gateway.stubs(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(empty_payment_methods_list)

    assert_raises(RuntimeError) do
      @gateway.purchase(@amount, nil, @options.merge(customer: "cus_ACH"))
    end
  end

  def test_purchase_uses_a_legacy_bank_account_id_as_the_payment_method
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_single_legacy_bank_account)
    @gateway.expects(:ssl_request).with do |_m, endpoint, post, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_intents") &&
        post.include?("payment_method=ba_legacy123")
    end.returns(successful_payment_intent_response("processing"))

    assert_success @gateway.purchase(@amount, nil, @options.merge(customer: "cus_ACH"))
  end

  # --- refund --------------------------------------------------------------------------------

  def test_refund_refunds_by_payment_intent
    @gateway.expects(:ssl_request).with do |_m, endpoint, post, _h|
      endpoint.start_with?("https://api.stripe.com/v1/refunds") &&
        post.include?("payment_intent=pi_ach123") &&
        post.include?("amount=200")
    end.returns(successful_refund_response)

    response = @gateway.refund(@refund_amount, "pi_ach123", @options)

    assert_success response
  end

  # --- unstore (detach) ----------------------------------------------------------------------

  def test_unstore_detaches_us_bank_account_payment_methods
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_single_bank_account)
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint == "https://api.stripe.com/v1/payment_methods/pm_bank123/detach"
    end.returns(successful_detach_response)

    assert_success @gateway.unstore("cus_ACH")
  end

  def test_unstore_is_a_noop_when_no_bank_account_pm_exists
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(empty_payment_methods_list)

    assert_success @gateway.unstore("cus_ACH")
  end

  def test_unstore_detaches_only_the_payment_method_named_in_the_identification
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_two_bank_accounts)
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint == "https://api.stripe.com/v1/payment_methods/pm_bank999/detach"
    end.returns(successful_detach_response)

    assert_success @gateway.unstore("cus_ACH|pm_bank999")
  end

  def test_unstore_detaches_a_legacy_bank_account_id
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_single_legacy_bank_account)
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint == "https://api.stripe.com/v1/payment_methods/ba_legacy123/detach"
    end.returns(successful_detach_response)

    assert_success @gateway.unstore("cus_ACH|ba_legacy123")
  end

  def test_unstore_raises_rather_than_detaching_every_method_when_the_profile_is_ambiguous
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint.start_with?("https://api.stripe.com/v1/payment_methods?customer")
    end.returns(payment_methods_list_with_two_bank_accounts)
    @gateway.expects(:ssl_request).with do |_m, endpoint, _p, _h|
      endpoint == "https://api.stripe.com/v1/customers/cus_ACH"
    end.returns(customer_without_default_payment_method)

    assert_raises(StripeCustomerManyPaymentMethodWithoutDefault) do
      @gateway.unstore("cus_ACH")
    end
  end

  private

  def stub_request_for(_endpoint, response)
    response
  end

  def expect_ssl_for(path_fragment, response)
    @gateway.expects(:ssl_request).with do |_method, endpoint, _post, _headers|
      endpoint.include?(path_fragment)
    end.returns(response)
  end

  # --- fixtures ------------------------------------------------------------------------------

  def successful_payment_method_response
    %({"id": "pm_bank123", "object": "payment_method", "type": "us_bank_account", "livemode": false})
  end

  def successful_new_customer_response
    %({"id": "cus_NEWACH123", "object": "customer", "sources": {"data": []}, "livemode": false})
  end

  def successful_setup_intent_response
    %({"id": "seti_ach123", "object": "setup_intent", "customer": "cus_NEWACH123", "payment_method": "pm_bank123", "status": "requires_action", "livemode": false})
  end

  def successful_payment_intent_response(status)
    %({"id": "pi_ach123", "object": "payment_intent", "status": "#{status}", "latest_charge": "ch_ach123", "livemode": false})
  end

  def successful_refund_response
    %({"id": "re_ach123", "object": "refund", "payment_intent": "pi_ach123", "status": "succeeded", "livemode": false})
  end

  def successful_detach_response
    %({"id": "pm_bank123", "object": "payment_method", "customer": null, "livemode": false})
  end

  def payment_methods_list_with_single_bank_account
    %({"object": "list", "data": [{"id": "pm_bank123", "type": "us_bank_account"}], "livemode": false})
  end

  def payment_methods_list_with_single_legacy_bank_account
    %({"object": "list", "data": [{"id": "ba_legacy123", "type": "us_bank_account"}], "livemode": false})
  end

  def payment_methods_list_with_two_bank_accounts
    %({"object": "list", "data": [{"id": "pm_bank123", "type": "us_bank_account"}, {"id": "pm_bank999", "type": "us_bank_account"}], "livemode": false})
  end

  def customer_without_default_payment_method
    %({"id": "cus_ACH", "object": "customer", "invoice_settings": {"default_payment_method": null}, "livemode": false})
  end

  def empty_payment_methods_list
    %({"object": "list", "data": [], "livemode": false})
  end
end
