require 'test_helper'

class StripeSetupIntentsTest < Test::Unit::TestCase
  include CommStub

  def setup
    @gateway = StripeSetupIntentsGateway.new(:login => 'login')
  end

  def test_inherits_from_stripe_gateway
    assert_kind_of StripeGateway, @gateway
  end

  def test_pins_modern_api_version_in_request_headers
    headers = @gateway.send(:headers)

    assert_equal StripeSetupIntentsGateway::SETUP_INTENTS_API_VERSION, headers["Stripe-Version"]
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

  def test_transaction_methods_are_not_implemented_in_scaffold
    assert_raises(NotImplementedError) { @gateway.store(nil) }
    assert_raises(NotImplementedError) { @gateway.purchase(100, nil) }
    assert_raises(NotImplementedError) { @gateway.refund(100, nil) }
  end
end
