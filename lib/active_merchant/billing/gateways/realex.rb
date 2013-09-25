require 'nokogiri'
require 'digest/sha1'

module ActiveMerchant
  module Billing
    # Realex is the leading CC gateway in Ireland
    # see http://www.realexpayments.com
    # Contributed by John Ward (john@ward.name)
    # see http://thinedgeofthewedge.blogspot.com
    #
    # Realex works using the following
    # login - The unique id of the merchant
    # password - The secret is used to digitally sign the request
    # account - This is an optional third part of the authentication process
    # and is used if the merchant wishes do distuinguish cc traffic from the different sources
    # by using a different account. This must be created in advance
    #
    # the Realex team decided to make the orderid unique per request,
    # so if validation fails you can not correct and resend using the
    # same order id
    class RealexGateway < Gateway
      class_attribute :live_vault_url, :test_vault_url

      self.live_url = self.test_url = 'https://epage.payandshop.com/epage-remote.cgi'
      self.live_vault_url = self.test_vault_url = 'https://epage.payandshop.com/epage-remote-plugins.cgi'

      CARD_MAPPING = {
        'master'            => 'MC',
        'visa'              => 'VISA',
        'american_express'  => 'AMEX',
        'diners_club'       => 'DINERS',
        'switch'            => 'SWITCH',
        'solo'              => 'SWITCH',
        'laser'             => 'LASER'
      }

      self.money_format = :cents
      self.default_currency = 'EUR'
      self.supported_cardtypes = [ :visa, :master, :american_express, :diners_club, :switch, :solo, :laser ]
      self.supported_countries = [ 'IE', 'GB' ]
      self.homepage_url = 'http://www.realexpayments.com/'
      self.display_name = 'Realex'

      SUCCESS, DECLINED          = "Successful", "Declined"
      BANK_ERROR = REALEX_ERROR  = "Gateway is in maintenance. Please try again later."
      ERROR = CLIENT_DEACTIVATED = "Gateway Error"

      def initialize(options = {})
        requires!(options, :login, :password)
        options[:refund_hash] = Digest::SHA1.hexdigest(options[:rebate_secret]) if options.has_key?(:rebate_secret)
        super
      end

      def purchase(money, credit_card_or_token, options = {})
        requires!(options, :order_id)

        request = if credit_card_or_token.is_a?(String)
          use_vault = true

          build_purchase_with_token(money, credit_card_or_token, options)
        else
          use_vault = false

          build_purchase_or_authorization_request(:purchase, money, credit_card_or_token, options)
        end

        commit(request, :use_vault => use_vault)
      end

      def authorize(money, creditcard, options = {})
        requires!(options, :order_id)

        request = build_purchase_or_authorization_request(:authorization, money, creditcard, options)
        commit(request)
      end

      def capture(money, authorization, options = {})
        request = build_capture_request(authorization, options)
        commit(request)
      end

      def refund(money, authorization, options = {})
        request = build_refund_request(money, authorization, options)
        commit(request)
      end

      def credit(money, authorization, options = {})
        deprecated CREDIT_DEPRECATION_MESSAGE
        refund(money, authorization, options)
      end

      def void(authorization, options = {})
        request = build_void_request(authorization, options)
        commit(request)
      end

      def store_payer(cc, options = {})
        request = build_payer_create_request(cc, options)
        commit(request, :use_vault => true, :token => build_token(options))
      end

      def store_card(cc, options = {})
        request = build_payment_method_create_request(cc, options)
        commit(request, :use_vault => true, :token => build_token(options))
      end

      def store(credit_card, options = {})
        options[:customer]       = options[:customer] || generate_unique_id[0...30]
        options[:card_reference] = options[:card_reference] || generate_unique_id[0...30]

        MultiResponse.new.tap do |r|
          r.process { store_payer(credit_card, options) }
          r.process { store_card(credit_card, options) }
        end
      end

      def update(token, credit_card, options = {})
        commit(build_update_request(token, credit_card, options), :use_vault => true, :token => token)
      end

      private

      def build_token(options)
        "#{options[:customer]};#{options[:card_reference]}"
      end

      def commit(request, params = {})
        params = { :use_vault => false, :token => nil }.merge(params)

        response = parse(ssl_post((params[:use_vault] ? self.live_vault_url : self.live_url), request))

        Response.new(response[:result] == "00", message_from(response), response,
          :test => (response[:message] =~ /\[ test system \]/ || test?),
          :authorization => params[:token] || authorization_from(response),
          :cvv_result => response[:cvnresult],
          :avs_result => {
            :street_match => response[:avspostcoderesponse],
            :postal_match => response[:avspostcoderesponse]
          }
        )
      end

      def parse(xml)
        response = {}

        doc = Nokogiri::XML(xml)
        doc.xpath('//response/*').each do |node|
          if (node.elements.size == 0)
            response[node.name.downcase.to_sym] = normalize(node.text)
          else
            node.elements.each do |childnode|
              name = "#{node.name.downcase}_#{childnode.name.downcase}"
              response[name.to_sym] = normalize(childnode.text)
            end
          end
        end unless doc.root.nil?

        response
      end

      def authorization_from(parsed, options = {})
        if options[:customer] && options[:card_reference]
          "#{options[:customer]}:#{options[:card_reference]}"
        else
          [parsed[:orderid], parsed[:pasref], parsed[:authcode]].join(';')
        end
      end

      def build_purchase_or_authorization_request(action, money, credit_card, options)
        timestamp = new_timestamp
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'auth' do
          add_merchant_details(xml, options)
          xml.tag! 'orderid', sanitize_order_id(options[:order_id])
          add_amount(xml, money, options)
          add_card(xml, credit_card)
          xml.tag! 'autosettle', 'flag' => auto_settle_flag(action)
          add_signed_digest(xml, timestamp, @options[:login], sanitize_order_id(options[:order_id]), amount(money), (options[:currency] || currency(money)), credit_card.number)
          add_comments(xml, options)
          add_address_and_customer_info(xml, options)
        end
        xml.target!
      end

      # TODO: CVN?
      def build_purchase_with_token(money, token, options)
        timestamp = new_timestamp
        token     = token.split(';')

        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'receipt-in' do
          add_merchant_details(xml, options)
          xml.tag! 'autosettle', 'flag' => 1
          xml.tag! 'orderid', sanitize_order_id(options[:order_id])

          xml.tag! 'paymentdata' do
            xml.tag! 'cvn' do
              xml.tag! 'number', options[:cvn]
            end
          end if options[:cvn]

          add_amount(xml, money, options)
          xml.tag! 'payerref', token[0]
          xml.tag! 'paymentmethod', token[1]
          add_signed_digest(xml, timestamp, @options[:login], sanitize_order_id(options[:order_id]), amount(money), options[:currency] || currency(money), token[0])
        end
      end

      def build_payer_create_request(credit_card, options)
        timestamp = new_timestamp

        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'payer-new' do
          add_merchant_details(xml, options)
          xml.tag! 'payer', :type => 'Business', :ref => options[:customer] do
            xml.tag! 'firstname', credit_card.first_name
            xml.tag! 'surname', credit_card.last_name
          end
          add_signed_digest(xml, timestamp, @options[:login], nil, nil, nil, options[:customer])
        end
        xml.target!
      end

      def build_payment_method_create_request(credit_card, options)
        timestamp = new_timestamp

        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'card-new' do
          add_merchant_details(xml, options)
          add_card(xml, credit_card, options)
          add_signed_digest(xml, timestamp, @options[:login], nil, nil, nil, options[:customer], credit_card.name, credit_card.number)
        end
        xml.target!
      end

      def build_update_request(token, credit_card, options)
        timestamp = new_timestamp
        options[:customer], options[:card_reference] = token.split(';')

        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'card-update-card' do
          add_merchant_details(xml, options)
          add_card(xml, credit_card, options)
          add_signed_digest(xml, timestamp, @options[:login], options[:customer], options[:card_reference], expiry_date(credit_card), credit_card.number)
        end
        xml.target!
      end

      def build_capture_request(authorization, options)
        timestamp = new_timestamp
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'settle' do
          add_merchant_details(xml, options)
          add_transaction_identifiers(xml, authorization, options)
          add_comments(xml, options)
          add_signed_digest(xml, timestamp, @options[:login], sanitize_order_id(options[:order_id]), nil, nil, nil)
        end
        xml.target!
      end

      def build_refund_request(money, authorization, options)
        timestamp = new_timestamp
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'rebate' do
          add_merchant_details(xml, options)
          add_transaction_identifiers(xml, authorization, options)
          xml.tag! 'amount', amount(money), 'currency' => options[:currency] || currency(money)
          xml.tag! 'refundhash', @options[:refund_hash] if @options[:refund_hash]
          xml.tag! 'autosettle', 'flag' => 1
          add_comments(xml, options)
          add_signed_digest(xml, timestamp, @options[:login], sanitize_order_id(options[:order_id]), amount(money), (options[:currency] || currency(money)), nil)
        end
        xml.target!
      end

      def build_void_request(authorization, options)
        timestamp = new_timestamp
        xml = Builder::XmlMarkup.new :indent => 2
        xml.tag! 'request', 'timestamp' => timestamp, 'type' => 'void' do
          add_merchant_details(xml, options)
          add_transaction_identifiers(xml, authorization, options)
          add_comments(xml, options)
          add_signed_digest(xml, timestamp, @options[:login], sanitize_order_id(options[:order_id]), nil, nil, nil)
        end
        xml.target!
      end

      def add_address_and_customer_info(xml, options)
        billing_address = options[:billing_address] || options[:address]
        shipping_address = options[:shipping_address]

        return unless billing_address || shipping_address || options[:customer] || options[:invoice] || options[:ip]

        xml.tag! 'tssinfo' do
          xml.tag! 'custnum', options[:customer] if options[:customer]
          xml.tag! 'prodid', options[:invoice] if options[:invoice]
          xml.tag! 'custipaddress', options[:ip] if options[:ip]

          if billing_address
            xml.tag! 'address', 'type' => 'billing' do
              xml.tag! 'code', format_shipping_zip_code(billing_address[:zip])
              xml.tag! 'country', billing_address[:country]
            end
          end

          if shipping_address
            xml.tag! 'address', 'type' => 'shipping' do
              xml.tag! 'code', format_shipping_zip_code(shipping_address[:zip])
              xml.tag! 'country', shipping_address[:country]
            end
          end
        end
      end

      def add_merchant_details(xml, options)
        xml.tag! 'merchantid', @options[:login]
        if options[:account] || @options[:account]
          xml.tag! 'account', (options[:account] || @options[:account])
        end
      end

      def add_transaction_identifiers(xml, authorization, options)
        options[:order_id], pasref, authcode = authorization.split(';')
        xml.tag! 'orderid', sanitize_order_id(options[:order_id])
        xml.tag! 'pasref', pasref
        xml.tag! 'authcode', authcode
      end

      def add_comments(xml, options)
        return unless options[:description]
        xml.tag! 'comments' do
          xml.tag! 'comment', options[:description], 'id' => 1
        end
      end

      def add_amount(xml, money, options)
        xml.tag! 'amount', amount(money), 'currency' => options[:currency] || currency(money)
      end

      def add_card(xml, credit_card, options = {})
        xml.tag! 'card' do
          xml.tag! 'number', credit_card.number
          xml.tag! 'expdate', expiry_date(credit_card)
          xml.tag! 'chname', credit_card.name
          xml.tag! 'type', CARD_MAPPING[card_brand(credit_card).to_s]
          xml.tag! 'issueno', credit_card.issue_number
          xml.tag! 'cvn' do
            xml.tag! 'number', credit_card.verification_value
            xml.tag! 'presind', (options['presind'] || (credit_card.verification_value? ? 1 : nil))
          end unless options[:card_reference]

          if options[:card_reference]
            xml.tag! 'ref', options[:card_reference]
            xml.tag! 'payerref', options[:customer]
          end
        end
      end

      def format_shipping_zip_code(zip)
        zip.to_s.gsub(/\W/, '')
      end

      def new_timestamp
        Time.now.strftime('%Y%m%d%H%M%S')
      end

      def add_signed_digest(xml, *values)
        string = Digest::SHA1.hexdigest(values.join("."))
        xml.tag! 'sha1hash', Digest::SHA1.hexdigest([string, @options[:password]].join("."))
        xml.tag! 'refundhash', Digest::SHA1.hexdigest(@options[:refund]) if @options[:refund]
      end

      def auto_settle_flag(action)
        action == :authorization ? '0' : '1'
      end

      def expiry_date(credit_card)
        "#{format(credit_card.month, :two_digits)}#{format(credit_card.year, :two_digits)}"
      end

      def normalize(field)
        case field
        when "true"   then true
        when "false"  then false
        when ""       then nil
        when "null"   then nil
        else field
        end
      end

      def message_from(response)
        message = nil
        case response[:result]
        when "00"
          message = SUCCESS
        when "101"
          message = response[:message]
        when "102", "103"
          message = DECLINED
        when /^2[0-9][0-9]/
          message = BANK_ERROR
        when /^3[0-9][0-9]/
          message = REALEX_ERROR
        when /^5[0-9][0-9]/
          message = response[:message]
        when "600", "601", "603"
          message = ERROR
        when "666"
          message = CLIENT_DEACTIVATED
        else
          message = DECLINED
        end
      end

      def sanitize_order_id(order_id)
        order_id.to_s.gsub(/[^a-zA-Z0-9\-_]/, '')
      end
    end
  end
end
