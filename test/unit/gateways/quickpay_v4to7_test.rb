require 'test_helper'

class QuickpayV4to7Test < Test::Unit::TestCase
  include CommStub

  def merchant_id
    "80000000000"
  end

  def setup
    @gateway = QuickpayGateway.new(
      :login => merchant_id,
      :password => 'PASSWORD',
      :version  => 7
    )

    @credit_card = credit_card('4242424242424242')
    @amount = 100
    @options = { :order_id => '1', :billing_address => address }
  end

  def test_successful_purchase
    @gateway.expects(:ssl_post).returns(successful_authorization_response, successful_capture_response)

    assert response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal '2865261', response.authorization
    assert response.test?
  end

  def test_successful_authorization
    @gateway.expects(:ssl_post).returns(successful_authorization_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_success response
    assert_equal '2865261', response.authorization
    assert response.test?
  end

  def test_successful_store_for_v6
    @gateway = QuickpayGateway.new(
      :login => merchant_id,
      :password => 'PASSWORD',
      :version => 6
    )
    @gateway.expects(:generate_check_hash).returns(mock_md5_hash)

    response = stub_comms do
      @gateway.store(@credit_card, {:order_id => 'fa73664073e23597bbdd', :description => 'Storing Card'})
    end.check_request do |endpoint, data, headers|
      assert_equal(expected_store_parameters_v6, CGI::parse(data))
    end.respond_with(successful_store_response_v6)

    assert response
    assert_instance_of Response, response
    assert_success response
    assert_equal '80760015', response.authorization
  end

  def test_successful_store_for_v7
    @gateway.expects(:generate_check_hash).returns(mock_md5_hash)

    response = stub_comms do
      @gateway.store(@credit_card, {:order_id => 'ed7546cb4ceb8f017ea4', :description => 'Storing Card'})
    end.check_request do |endpoint, data, headers|
      assert_equal(expected_store_parameters_v7, CGI::parse(data))
    end.respond_with(successful_store_response_v7)

    assert response
    assert_instance_of Response, response
    assert_success response
    assert_equal '80758573', response.authorization
  end

  def test_failed_authorization
    @gateway.expects(:ssl_post).returns(failed_authorization_response)

    assert response = @gateway.authorize(@amount, @credit_card, @options)
    assert_failure response
    assert_equal 'Missing/error in card verification data', response.message
    assert response.test?
  end

  def test_parsing_response_with_errors
    @gateway.expects(:ssl_post).returns(error_response)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
    assert_equal '008', response.params['qpstat']
    assert_equal 'Missing/error in cardnumber, Missing/error in expirationdate, Missing/error in card verification data, Missing/error in amount, Missing/error in ordernum, Missing/error in currency', response.params['qpstatmsg']
    assert_equal 'Missing/error in cardnumber, Missing/error in expirationdate, Missing/error in card verification data, Missing/error in amount, Missing/error in ordernum, Missing/error in currency', response.message
  end

  def test_merchant_error
    @gateway.expects(:ssl_post).returns(merchant_error)

    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_failure response
    assert_equal response.message, 'Missing/error in merchant'
  end

  def test_parsing_successful_response
    @gateway.expects(:ssl_post).returns(successful_authorization_response)

    response = @gateway.authorize(@amount, @credit_card, @options)

    assert_success response
    assert_equal 'OK', response.message

    assert_equal '2865261', response.authorization
    assert_equal '000', response.params['qpstat']
    assert_equal '000', response.params['pbsstat']
    assert_equal '2865261', response.params['transaction']
    assert_equal '070425223705', response.params['time']
    assert_equal '104680', response.params['ordernum']
    assert_equal 'cody@example.com', response.params['merchantemail']
    assert_equal 'Visa', response.params['cardtype']
    assert_equal @amount.to_s, response.params['amount']
    assert_equal 'OK', response.params['qpstatmsg']
    assert_equal 'Shopify', response.params['merchant']
    assert_equal '1110', response.params['msgtype']
    assert_equal 'USD', response.params['currency']
  end

  def test_supported_countries
    klass = @gateway.class
    assert_equal ['DE', 'DK', 'ES', 'FI', 'FR', 'FO', 'GB', 'IS', 'NO', 'SE'], klass.supported_countries
  end

  def test_supported_card_types
    klass = @gateway.class
    assert_equal  [ :dankort, :forbrugsforeningen, :visa, :master, :american_express, :diners_club, :jcb, :maestro ], klass.supported_cardtypes
  end

  def test_finalize_is_disabled_by_default
    stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, "12345")
    end.check_request do |method, endpoint, data, headers|
      assert data =~ /finalize=0/
    end.respond_with(successful_capture_response)
  end

  def test_finalize_is_enabled
    stub_comms(@gateway, :ssl_request) do
      @gateway.capture(@amount, "12345", finalize: true)
    end.check_request do |method, endpoint, data, headers|
      assert data =~ /finalize=1/
    end.respond_with(successful_capture_response)
  end

  def test_scrub
    assert_equal @gateway.scrub(pre_scrubbed), post_scrubbed
  end

  def test_supports_scrubbing?
    assert @gateway.supports_scrubbing?
  end

  private

  def error_response
    "<?xml version='1.0' encoding='ISO-8859-1'?><response><qpstat>008</qpstat><qpstatmsg>Missing/error in cardnumber, Missing/error in expirationdate, Missing/error in card verification data, Missing/error in amount, Missing/error in ordernum, Missing/error in currency</qpstatmsg></response>"
  end

  def merchant_error
    "<?xml version='1.0' encoding='ISO-8859-1'?><response><qpstat>008</qpstat><qpstatmsg>Missing/error in merchant</qpstatmsg></response>"
  end

  def successful_authorization_response
    "<?xml version='1.0' encoding='ISO-8859-1'?><response><qpstat>000</qpstat><transaction>2865261</transaction><time>070425223705</time><ordernum>104680</ordernum><merchantemail>cody@example.com</merchantemail><pbsstat>000</pbsstat><cardtype>Visa</cardtype><amount>100</amount><qpstatmsg>OK</qpstatmsg><merchant>Shopify</merchant><msgtype>1110</msgtype><currency>USD</currency></response>"
  end

  def successful_capture_response
    '<?xml version="1.0" encoding="ISO-8859-1"?><response><msgtype>1230</msgtype><amount>100</amount><time>080107061755</time><pbsstat>000</pbsstat><qpstat>000</qpstat><qpstatmsg>OK</qpstatmsg><currency>DKK</currency><ordernum>4820346075804536193</ordernum><transaction>2865261</transaction><merchant>Shopify</merchant><merchantemail>pixels@jadedpixel.com</merchantemail></response>'
  end

  def successful_store_response_v6
    '<?xml version="1.0" encoding="UTF-8"?><response><msgtype>subscribe</msgtype><ordernumber>fa73664073e23597bbdd</ordernumber><amount>0</amount><currency>n/a</currency><time>2014-02-26T21:25:47+01:00</time><state>9</state><qpstat>000</qpstat><qpstatmsg>OK</qpstatmsg><chstat>000</chstat><chstatmsg>OK</chstatmsg><merchant>Test Merchant</merchant><merchantemail>merchant@example.com</merchantemail><transaction>80760015</transaction><cardtype>visa</cardtype><cardnumber>XXXXXXXXXXXX4242</cardnumber><cardexpire>1509</cardexpire><splitpayment/><fraudprobability/><fraudremarks/><fraudreport/><md5check>mock_hash</md5check></response>'
  end

  def successful_store_response_v7
    '<?xml version="1.0" encoding="UTF-8"?><response><msgtype>subscribe</msgtype><ordernumber>ed7546cb4ceb8f017ea4</ordernumber><amount>0</amount><currency>DKK</currency><time>2014-02-26T21:04:00+01:00</time><state>9</state><qpstat>000</qpstat><qpstatmsg>OK</qpstatmsg><chstat>000</chstat><chstatmsg>OK</chstatmsg><merchant>Test Merchant</merchant><merchantemail>merchant@example.com</merchantemail><transaction>80758573</transaction><cardtype>visa</cardtype><cardnumber>XXXXXXXXXXXX4242</cardnumber><cardexpire>1509</cardexpire><splitpayment/><acquirer>nets</acquirer><fraudprobability/><fraudremarks/><fraudreport/><md5check>mock_hash</md5check></response>'
  end

  def failed_authorization_response
    '<?xml version="1.0" encoding="ISO-8859-1"?><response><qpstat>008</qpstat><qpstatmsg>Missing/error in card verification data</qpstatmsg></response>'
  end

  def expected_store_parameters_v6
    {
      "amount"=>["0"],
      "cardnumber"=>["4242424242424242"],
      "currency"=>["DKK"],
      "cvd"=>["123"],
      "expirationdate"=>[expected_expiration_date],
      "ordernumber"=>["fa73664073e23597bbdd"],
      "description"=>["Storing Card"],
      "protocol"=>["6"],
      "msgtype"=>["subscribe"],
      "merchant"=>[merchant_id],
      "md5check"=>[mock_md5_hash]
    }
  end

  def expected_store_parameters_v7
    {
      "amount"=>["0"],
      "currency"=>["DKK"],
      "cardnumber"=>["4242424242424242"],
      "cvd"=>["123"],
      "expirationdate"=>[expected_expiration_date],
      "ordernumber"=>["ed7546cb4ceb8f017ea4"],
      "description"=>["Storing Card"],
      "protocol"=>["7"],
      "msgtype"=>["subscribe"],
      "merchant"=>[merchant_id],
      "md5check"=>[mock_md5_hash]
    }
  end

  def expected_expiration_date
    '%02d%02d' % [@credit_card.year.to_s[2..4], @credit_card.month]
  end

  def mock_md5_hash
    "mock_hash"
  end

  def pre_scrubbed
    <<-PRE_SCRUBBED
    opening connection to secure.quickpay.dk:443...
    opened
    starting SSL for secure.quickpay.dk:443...
    SSL established
    <- "POST /api HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: secure.quickpay.dk\r\nContent-Length: 227\r\n\r\n"
    <- "cardnumber=1000000000000008&cvd=111&expirationdate=2402&amount=0&currency=USD&ordernumber=2019101013403177aa25&description=Longbob+Longsen&protocol=3&msgtype=subscribe&merchant=12345677777&apikey=fB46983ZwRadzy46A3r6ngDx7P37N5YTu1F4S9W2JKCs9v4t5L9m2Q8Mlbjpa2I1&md5check=ea118e189f9dc81d18c1c90f4c29b680"
    -> "HTTP/1.1 200 OK\r\n"
    -> "Server: nginx\r\n"
    -> "Date: Thu, 10 Oct 2019 13:40:33 GMT\r\n"
    -> "Content-Type: application/xml; charset=utf-8\r\n"
    -> "Transfer-Encoding: chunked\r\n"
    -> "Connection: close\r\n"
    -> "Strict-Transport-Security: max-age=15768000\r\n"
    -> "Strict-Transport-Security: max-age=15768000\r\n"
    -> "\r\n"
    -> "27e\r\n"
    reading 638 bytes...
    -> "<?xml version=\"1.0\" encoding=\"UTF-8\"?><response><msgtype>subscribe</msgtype><ordernumber>2019101013403177aa25</ordernumber><amount>0</amount><currency>USD</currency><time>191010134032</time><state>9</state><qpstat>000</qpstat><qpstatmsg>OK</qpstatmsg><chstat>20000</chstat><chstatmsg>Approved</chstatmsg><merchant>Chargify QuickPay Proxy</merchant><merchantemail>dev+quickpay-proxy@chargify.com</merchantemail><transaction>162719766</transaction><cardtype>visa-dk</cardtype><cardnumber>XXXXXXXXXXXX0008</cardnumber><cardexpire>2402</cardexpire><splitpayment>1</splitpayment><md5check>a480503384c5d3103a2081e852a83634</md5check></response>"
    read 638 bytes
    reading 2 bytes...
    -> "\r\n"
    read 2 bytes
    -> "0\r\n"
    -> "\r\n"
    Conn close
    PRE_SCRUBBED
  end

  def post_scrubbed
    <<-POST_SCRUBBED
    opening connection to secure.quickpay.dk:443...
    opened
    starting SSL for secure.quickpay.dk:443...
    SSL established
    <- "POST /api HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nAccept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3\r\nAccept: */*\r\nUser-Agent: Ruby\r\nConnection: close\r\nHost: secure.quickpay.dk\r\nContent-Length: 227\r\n\r\n"
    <- "cardnumber=[FILTERED]&cvd=[FILTERED]&expirationdate=2402&amount=0&currency=USD&ordernumber=2019101013403177aa25&description=Longbob+Longsen&protocol=3&msgtype=subscribe&merchant=[FILTERED]&apikey=[FILTERED]&md5check=ea118e189f9dc81d18c1c90f4c29b680"
    -> "HTTP/1.1 200 OK\r\n"
    -> "Server: nginx\r\n"
    -> "Date: Thu, 10 Oct 2019 13:40:33 GMT\r\n"
    -> "Content-Type: application/xml; charset=utf-8\r\n"
    -> "Transfer-Encoding: chunked\r\n"
    -> "Connection: close\r\n"
    -> "Strict-Transport-Security: max-age=15768000\r\n"
    -> "Strict-Transport-Security: max-age=15768000\r\n"
    -> "\r\n"
    -> "27e\r\n"
    reading 638 bytes...
    -> "<?xml version=\"1.0\" encoding=\"UTF-8\"?><response><msgtype>subscribe</msgtype><ordernumber>2019101013403177aa25</ordernumber><amount>0</amount><currency>USD</currency><time>191010134032</time><state>9</state><qpstat>000</qpstat><qpstatmsg>OK</qpstatmsg><chstat>20000</chstat><chstatmsg>Approved</chstatmsg><merchant>Chargify QuickPay Proxy</merchant><merchantemail>dev+quickpay-proxy@chargify.com</merchantemail><transaction>162719766</transaction><cardtype>visa-dk</cardtype><cardnumber>XXXXXXXXXXXX0008</cardnumber><cardexpire>2402</cardexpire><splitpayment>1</splitpayment><md5check>a480503384c5d3103a2081e852a83634</md5check></response>"
    read 638 bytes
    reading 2 bytes...
    -> "\r\n"
    read 2 bytes
    -> "0\r\n"
    -> "\r\n"
    Conn close
    POST_SCRUBBED
  end
end
