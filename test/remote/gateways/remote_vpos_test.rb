require 'test_helper'

class RemoteVposTest < Test::Unit::TestCase
  def setup
    @gateway = VposGateway.new(fixtures(:vpos))

    # some test fails due duplicated transactions
    @amount = rand(100..100000)
    @credit_card = credit_card('5418630110000014', month: 8, year: 2026, verification_value: '277')
    @declined_card = credit_card('4000300011112220')
    @options = {
      billing_address: address,
      description: 'Store Purchase'
    }
  end

  def test_successful_purchase
    response = @gateway.purchase(@amount, @credit_card, @options)
    assert_success response
    assert_equal 'Transaccion aprobada', response.message
  end

  def test_failed_purchase
    response = @gateway.purchase(@amount, @declined_card, @options)
    assert_failure response
    assert_equal 'EMISOR NO RECONOCIDO', response.message
  end

  def test_successful_inquire_transaction_id
    assert purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase
    assert inquire = @gateway.inquire(purchase.authorization)
    assert_success inquire

    assert inquire.authorization, purchase.authorization
    assert_equal 'Transaccion aprobada', inquire.message
  end

  def test_successful_inquire_shop_process_id
    shop_process_id = SecureRandom.random_number(10**15)

    assert purchase = @gateway.purchase(@amount, @credit_card, @options.merge(shop_process_id:))
    assert_success purchase
    assert inquire = @gateway.inquire(nil, { shop_process_id: })
    assert_success inquire

    assert inquire.authorization, purchase.authorization
    assert_equal 'Transaccion aprobada', inquire.message
  end

  def test_successful_refund_using_auth
    shop_process_id = SecureRandom.random_number(10**15)

    assert purchase = @gateway.purchase(@amount, @credit_card, @options)
    assert_success purchase
    authorization = purchase.authorization

    assert refund = @gateway.refund(@amount, authorization, @options.merge(shop_process_id:))
    assert_failure refund
    assert_equal 'Transaccion denegada', refund.message
  end

  def test_successful_refund_using_shop_process_id
    shop_process_id = SecureRandom.random_number(10**15)

    assert purchase = @gateway.purchase(@amount, @credit_card, @options.merge(shop_process_id:))
    assert_success purchase

    assert refund = @gateway.refund(@amount, nil, original_shop_process_id: shop_process_id) # 315300749110268, 21611732218038
    assert_failure refund
    assert_equal 'Transaccion denegada', refund.message
  end

  def test_successful_credit
    assert credit = @gateway.credit(@amount, @credit_card)
    assert_success credit
    assert_equal 'Transaccion aprobada', credit.message
  end

  def test_failed_credit
    response = @gateway.credit(@amount, @declined_card)
    assert_equal 'Transaccion denegada', response.message
  end

  def test_successful_void
    shop_process_id = SecureRandom.random_number(10**15)
    options = @options.merge({ shop_process_id: })

    purchase = @gateway.purchase(@amount, @credit_card, options)
    assert_success purchase

    assert void = @gateway.void(purchase.authorization, options)
    assert_success void
    assert_equal 'RollbackSuccessful:Transacción Aprobada', void.message
  end

  def test_duplicate_void_fails
    shop_process_id = SecureRandom.random_number(10**15)
    options = @options.merge({ shop_process_id: })

    purchase = @gateway.purchase(@amount, @credit_card, options)
    assert_success purchase

    assert void = @gateway.void(purchase.authorization, options)
    assert_success void
    assert_equal 'RollbackSuccessful:Transacción Aprobada', void.message

    assert duplicate_void = @gateway.void(purchase.authorization, options)
    assert_failure duplicate_void
    assert_equal 'AlreadyRollbackedError:The payment has already been rollbacked.', duplicate_void.message
  end

  def test_failed_void
    response = @gateway.void('abc#123')
    assert_failure response
    assert_equal 'BuyNotFoundError:Buy not found with shop_process_id=123.', response.message
  end

  def test_invalid_login
    gateway = VposGateway.new(private_key: '', public_key: '', encryption_key: OpenSSL::PKey::RSA.new(512), commerce: 123, commerce_branch: 45)

    response = gateway.void('')
    assert_failure response
    assert_match %r{InvalidPublicKeyError}, response.message
  end

  def test_transcript_scrubbing
    transcript = capture_transcript(@gateway) do
      @gateway.purchase(@amount, @credit_card, @options)
    end
    transcript = @gateway.scrub(transcript)

    # does not contain anything other than '[FILTERED]'
    assert_no_match(/token\\":\\"[^\[FILTERD\]]/, transcript)
    assert_no_match(/card_encrypted_data\\":\\"[^\[FILTERD\]]/, transcript)
  end
end
