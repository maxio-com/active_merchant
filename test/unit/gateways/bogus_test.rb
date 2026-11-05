require 'test_helper'

class BogusTest < Test::Unit::TestCase
  CC_SUCCESS_PLACEHOLDER = '4444333322221111'
  CC_FAILURE_PLACEHOLDER = '4444333311112222'
  CHECK_SUCCESS_PLACEHOLDER = '111111111111'
  CHECK_FAILURE_PLACEHOLDER = '222222222222'

  SUCCESS_CARD = '4111111111111111'.freeze
  DECLINE_CARD = '4000000000000002'.freeze
  TXN_REFERENCE = 'bogus_txn_1a2b3c4d5e6f7a8b'.freeze
  TXN_ID = /\Abogus_txn_\h{16}\z/.freeze
  LIVE_SITE_MESSAGE = 'Test Gateway: transactions always fail on live Sites. Connect a real gateway.'.freeze
  NETWORK_ERRORS = {
    '0028' => [Timeout::Error, 'The connection to the remote server timed out'],
    '0036' => [OpenSSL::SSL::SSLError, 'The SSL connection to the remote server could not be established'],
    '0044' => [Errno::ECONNRESET, 'The remote server reset the connection']
  }.freeze

  def setup
    @gateway = BogusGateway.new(
      :login => 'bogus',
      :password => 'bogus'
    )

    @options = { live_site: false }
    @store_options = { live_site: false, site_id: 4821 }
  end

  # Phase 1: test cards and live-Site failure (E1, E3, E4, E7, E8)

  def test_purchase_with_success_card_returns_a_unique_transaction_id
    first = @gateway.purchase(1000, credit_card(SUCCESS_CARD), @options)
    second = @gateway.purchase(1000, credit_card(SUCCESS_CARD), @options)

    assert_transaction first
    assert_transaction second
    assert_not_equal first.authorization, second.authorization
  end

  def test_purchase_with_token_ending_1111_succeeds
    assert_transaction @gateway.purchase(1000, 'bogus_4821_9f3a1c7e_1111', @options)
  end

  def test_purchase_with_card_or_token_ending_0002_declines
    [credit_card(DECLINE_CARD), 'bogus_4821_9f3a1c7e_0002'].each do |paysource|
      response = @gateway.purchase(1000, paysource, @options)

      assert_decline response
      assert_equal BogusGateway::FAILURE_MESSAGE, response.message
    end
  end

  def test_network_error_cards_and_tokens_raise_connection_error
    NETWORK_ERRORS.each do |last4, (exception, message)|
      [credit_card("400000000000#{last4}"), "bogus_4821_9f3a1c7e_#{last4}"].each do |paysource|
        assert_connection_error(exception, message) { @gateway.purchase(1000, paysource, @options) }
        assert_connection_error(exception, message) { @gateway.authorize(1000, paysource, @options) }
        assert_connection_error(exception, message) { @gateway.verify(paysource, @options) }
      end
    end
  end

  def test_purchase_with_legacy_tokens_keeps_todays_outcome
    assert_transaction @gateway.purchase(1000, '1', @options)
    assert_decline @gateway.purchase(1000, '2', @options)
  end

  def test_purchase_on_legacy_authorization_succeeds_as_today
    response = @gateway.purchase(1000, BogusGateway::AUTHORIZATION, @options)

    assert response.success?
    assert_equal BogusGateway::AUTHORIZATION, response.authorization
  end

  def test_any_other_last_digit_raises_billing_error
    [credit_card('5555555555554444'), 'bogus_4821_9f3a1c7e_4444', '3'].each do |paysource|
      assert_billing_error { @gateway.purchase(1000, paysource, @options) }
      assert_billing_error { @gateway.authorize(1000, paysource, @options) }
      assert_billing_error { @gateway.verify(paysource, @options) }
    end
  end

  def test_authorize_and_verify_follow_the_purchase_table
    assert_transaction @gateway.authorize(1000, credit_card(SUCCESS_CARD), @options)
    assert_transaction @gateway.verify(credit_card(SUCCESS_CARD), @options)
    assert_decline @gateway.authorize(1000, credit_card(DECLINE_CARD), @options)
    assert_decline @gateway.verify(credit_card(DECLINE_CARD), @options)
  end

  def test_live_site_fails_charges_before_any_card_rule
    live = { live_site: true }
    paysources = [credit_card(SUCCESS_CARD), credit_card('4000000000000028'), credit_card('123', icc_data: 'DEADBEEF'),
                  check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil)]

    paysources.each do |paysource|
      assert_live_site_failure @gateway.purchase(1000, paysource, live)
      assert_live_site_failure @gateway.authorize(1000, paysource, live)
      assert_live_site_failure @gateway.verify(paysource, live)
      assert_live_site_failure @gateway.credit(1000, paysource, live)
    end
  end

  def test_live_site_fails_refund_capture_void_and_store
    live = { live_site: true, site_id: 4821 }

    assert_live_site_failure @gateway.refund(1000, TXN_REFERENCE, live)
    assert_live_site_failure @gateway.capture(1000, TXN_REFERENCE, live)
    assert_live_site_failure @gateway.void(TXN_REFERENCE, live)
    assert_live_site_failure @gateway.store(credit_card(SUCCESS_CARD), live)
    assert_live_site_failure @gateway.store(check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), live)
  end

  def test_live_site_failures_carry_amount_and_last_four
    live = { live_site: true }
    purchase = @gateway.purchase(1000, credit_card(SUCCESS_CARD), live)
    verify = @gateway.verify(credit_card(SUCCESS_CARD), live)

    assert_equal ['10.00', '1111', nil], purchase.params.values_at('paid_amount', 'last4', 'authorization')
    assert_equal ['1111', nil], verify.params.values_at('last4', 'authorization')
  end

  def test_missing_or_non_boolean_live_site_raises_on_charges
    paysources = [credit_card(SUCCESS_CARD), credit_card('4000000000000028'), credit_card('123', icc_data: 'DEADBEEF'),
                  check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil)]

    paysources.each do |paysource|
      [{}, { live_site: nil }, { live_site: 'false' }].each do |options|
        assert_raises(ArgumentError) { @gateway.purchase(1000, paysource, options) }
        assert_raises(ArgumentError) { @gateway.authorize(1000, paysource, options) }
        assert_raises(ArgumentError) { @gateway.verify(paysource, options) }
        assert_raises(ArgumentError) { @gateway.credit(1000, paysource, options) }
      end
    end
  end

  def test_missing_or_non_boolean_live_site_raises_on_references_and_store
    [{}, { live_site: nil }, { live_site: 'false' }].each do |options|
      assert_raises(ArgumentError) { @gateway.refund(1000, TXN_REFERENCE, options) }
      assert_raises(ArgumentError) { @gateway.capture(1000, TXN_REFERENCE, options) }
      assert_raises(ArgumentError) { @gateway.void(TXN_REFERENCE, options) }
      assert_raises(ArgumentError) { @gateway.store(credit_card(SUCCESS_CARD), options.merge(site_id: 4821)) }
    end
  end

  # Fails a public operation added later without the live_site guard (E4).
  def test_every_public_operation_except_unstore_requires_live_site
    operations = BogusGateway.public_instance_methods(false) - [:unstore]
    refute_empty operations

    operations.each do |operation|
      required = @gateway.method(operation).parameters.count { |type, _| type == :req }
      error = assert_raises(ArgumentError, operation.to_s) { @gateway.public_send(operation, *[1] * required, {}) }
      assert_match(/live_site/, error.message)
    end
  end

  def test_refund_capture_and_void_succeed_for_any_reference
    [TXN_REFERENCE, BogusGateway::AUTHORIZATION, '1', '2'].each do |reference|
      assert_transaction @gateway.refund(1000, reference, @options)
      assert_transaction @gateway.capture(1000, reference, @options)
      assert_transaction @gateway.void(reference, @options)
    end
  end

  def test_charge_responses_carry_amount_last_four_and_authorization
    purchase = @gateway.purchase(1000, credit_card(SUCCESS_CARD), @options)
    authorize = @gateway.authorize(1000, 'bogus_4821_9f3a1c7e_1111', @options)

    assert_equal ['10.00', '1111', purchase.authorization],
                 purchase.params.values_at('paid_amount', 'last4', 'authorization')
    assert_equal ['10.00', '1111', authorize.authorization],
                 authorize.params.values_at('authorized_amount', 'last4', 'authorization')
  end

  def test_verify_and_decline_responses_carry_last_four_and_authorization
    verify = @gateway.verify(credit_card(SUCCESS_CARD), @options)
    decline = @gateway.purchase(1000, credit_card(DECLINE_CARD), @options)

    assert_equal ['1111', verify.authorization], verify.params.values_at('last4', 'authorization')
    assert_equal ['10.00', '0002', nil], decline.params.values_at('paid_amount', 'last4', 'authorization')
  end

  def test_refund_and_capture_responses_carry_amount_and_authorization
    refund = @gateway.refund(500, TXN_REFERENCE, @options)
    capture = @gateway.capture(500, TXN_REFERENCE, @options)

    assert_equal ['5.00', refund.authorization], refund.params.values_at('paid_amount', 'authorization')
    assert_equal ['5.00', capture.authorization], capture.params.values_at('paid_amount', 'authorization')
  end

  def test_credit
    assert  @gateway.credit(1000, credit_card(CC_SUCCESS_PLACEHOLDER), @options).success?
    response =  @gateway.credit(1000, credit_card(CC_FAILURE_PLACEHOLDER), @options)
    refute response.success?
    assert_equal Gateway::STANDARD_ERROR_CODE[:processing_error], response.error_code
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.credit(1000, credit_card('123'), @options)
    end
    assert_equal("Bogus Gateway: Use CreditCard number ending in 1 for success, 2 for exception and anything else for error", e.message)
  end

  def test_credit_uses_refund
    options = {:foo => :bar}
    @gateway.expects(:refund).with(1000, '1337', options)
    assert_deprecation_warning(Gateway::CREDIT_DEPRECATION_MESSAGE) do
      @gateway.credit(1000, '1337', options)
    end
  end

  # Phase 2: real-looking tokens on card storage (E1, E5, E6, E7, E10)

  def test_store_returns_a_bogus_token_with_site_id_and_last_four
    response = @gateway.store(credit_card(SUCCESS_CARD), @store_options)

    assert response.success?
    assert_match(/\Abogus_4821_\h{8}_1111\z/, response.authorization)
    assert_equal [response.authorization, '1111'], response.params.values_at('billingid', 'last4')
  end

  def test_storing_the_same_card_twice_returns_different_tokens
    first = @gateway.store(credit_card(SUCCESS_CARD), @store_options)
    second = @gateway.store(credit_card(SUCCESS_CARD), @store_options)

    assert_not_equal first.authorization, second.authorization
  end

  def test_store_of_decline_and_network_error_cards_succeeds
    %w[0002 0028 0036 0044].each do |last4|
      response = @gateway.store(credit_card("400000000000#{last4}"), @store_options)

      assert_match(/\Abogus_4821_\h{8}_#{last4}\z/, response.authorization)
    end
  end

  def test_store_without_site_id_raises_argument_error
    [@options, @options.merge(site_id: nil), @options.merge(site_id: '')].each do |options|
      assert_raises(ArgumentError) { @gateway.store(credit_card(SUCCESS_CARD), options) }
    end
  end

  def test_store_of_card_ending_in_3_raises_billing_error
    assert_billing_error('Bogus Gateway: Card numbers ending in 3 always fail to store') do
      @gateway.store(credit_card('4012000033330323'), @store_options)
    end
  end

  def test_stored_token_charges_by_its_last_four
    success_token = @gateway.store(credit_card(SUCCESS_CARD), @store_options).authorization
    decline_token = @gateway.store(credit_card(DECLINE_CARD), @store_options).authorization

    assert_transaction @gateway.purchase(1000, success_token, @options)
    assert_decline @gateway.purchase(1000, decline_token, @options)
  end

  def test_unstore_succeeds_for_any_token_even_on_live_sites
    %w[bogus_4821_9f3a1c7e_1111 1 2 3].each do |token|
      assert @gateway.unstore(token).success?
      assert @gateway.unstore(token, live_site: true).success?
    end
  end

  def test_supported_countries
    assert_equal [], BogusGateway.supported_countries
  end

  def test_supported_card_types
    assert_equal [:bogus], BogusGateway.supported_cardtypes
  end

  def test_authorize_with_check
    assert  @gateway.authorize(1000, check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options).success?
    assert !@gateway.authorize(1000, check(account_number: CHECK_FAILURE_PLACEHOLDER, number: nil), @options).success?
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.authorize(1000, check(account_number: '123', number: nil), @options)
    end
    assert_equal("Bogus Gateway: Use bank account number ending in 1 for success, 2 for exception and anything else for error", e.message)
  end

  def test_purchase_with_check
    # use account number if number isn't given
    assert  @gateway.purchase(1000, check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options).success?
    assert !@gateway.purchase(1000, check(account_number: CHECK_FAILURE_PLACEHOLDER, number: nil), @options).success?
    # give priority to number over account_number if given
    assert !@gateway.purchase(1000, check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: CHECK_FAILURE_PLACEHOLDER), @options).success?
    assert  @gateway.purchase(1000, check(account_number: CHECK_FAILURE_PLACEHOLDER, number: CHECK_SUCCESS_PLACEHOLDER), @options).success?
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.purchase(1000, check(account_number: '123', number: nil), @options)
    end
    assert_equal("Bogus Gateway: Use bank account number ending in 1 for success, 2 for exception and anything else for error", e.message)
  end

  def test_store_with_check
    assert  @gateway.store(check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options).success?
    assert !@gateway.store(check(account_number: CHECK_FAILURE_PLACEHOLDER, number: nil), @options).success?
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.store(check(account_number: '123', number: nil), @options)
    end
    assert_equal("Bogus Gateway: Use bank account number ending in 1 for success, 2 for exception and anything else for error", e.message)
  end

  def test_bank_account_store_and_authorize_return_todays_ids
    store = @gateway.store(check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options)
    authorize = @gateway.authorize(1000, check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options)

    assert_equal ['1', BogusGateway::AUTHORIZATION], [store.params['billingid'], store.authorization]
    assert_equal BogusGateway::AUTHORIZATION, authorize.authorization
  end

  def test_verify_with_check
    response = @gateway.verify(check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options)

    assert_equal ['1', BogusGateway::AUTHORIZATION], [response.params['billingid'], response.authorization]
    refute @gateway.verify(check(account_number: CHECK_FAILURE_PLACEHOLDER, number: nil), @options).success?
    assert_billing_error(BogusGateway::CHECK_ERROR_MESSAGE) do
      @gateway.verify(check(account_number: '123', number: nil), @options)
    end
  end

  def test_credit_with_check
    assert  @gateway.credit(1000, check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options).success?
    assert !@gateway.credit(1000, check(account_number: CHECK_FAILURE_PLACEHOLDER, number: nil), @options).success?
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.credit(1000, check(account_number: '123', number: nil), @options)
    end
    assert_equal("Bogus Gateway: Use bank account number ending in 1 for success, 2 for exception and anything else for error", e.message)
  end

  def test_store_then_purchase_with_check
    reference = @gateway.store(check(account_number: CHECK_SUCCESS_PLACEHOLDER, number: nil), @options)
    assert @gateway.purchase(1000, reference.authorization, @options).success?
  end

  def test_authorize_emv
    approve_response = @gateway.authorize(1000, credit_card('123', {icc_data: 'DEADBEEF'}), @options)
    assert approve_response.success?
    assert_equal '8A023030', approve_response.emv_authorization
    decline_response = @gateway.authorize(1005, credit_card('123', {icc_data: 'DEADBEEF'}), @options)
    refute decline_response.success?
    assert_equal Gateway::STANDARD_ERROR_CODE[:processing_error], decline_response.error_code
    assert_equal '8A023035', decline_response.emv_authorization
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.authorize(1001, credit_card('123', {icc_data: 'DEADBEEF'}), @options)
    end
    assert_equal("Bogus Gateway: Use amount ending in 00 for success, 05 for failure and anything else for exception", e.message)
  end

  def test_purchase_emv
    assert  @gateway.purchase(1000, credit_card('123', {icc_data: 'DEADBEEF'}), @options).success?
    response = @gateway.purchase(1005, credit_card('123', {icc_data: 'DEADBEEF'}), @options)
    refute response.success?
    assert_equal Gateway::STANDARD_ERROR_CODE[:processing_error], response.error_code
    e = assert_raises(ActiveMerchant::Billing::Error) do
      @gateway.purchase(1001, credit_card('123', {icc_data: 'DEADBEEF'}), @options)
    end
    assert_equal("Bogus Gateway: Use amount ending in 00 for success, 05 for failure and anything else for exception", e.message)
  end

  private

  def assert_transaction(response)
    assert response.success?, response.message
    assert response.test?
    assert_match TXN_ID, response.authorization
  end

  def assert_decline(response)
    refute response.success?
    assert response.test?
    assert_equal Gateway::STANDARD_ERROR_CODE[:processing_error], response.error_code
    assert_nil response.authorization
    assert response.params.key?('authorization')
    assert_equal response.message, response.params['error']
  end

  def assert_live_site_failure(response)
    assert_decline response
    assert_equal LIVE_SITE_MESSAGE, response.message
  end

  def assert_connection_error(exception, message, &block)
    error = assert_raises(ActiveMerchant::ConnectionError, &block)
    assert_equal message, error.message
    assert_kind_of exception, error.triggering_exception
  end

  def assert_billing_error(message = BogusGateway::NUMBER_ERROR_MESSAGE, &block)
    error = assert_raises(ActiveMerchant::Billing::Error, &block)
    assert_equal message, error.message
  end
end
