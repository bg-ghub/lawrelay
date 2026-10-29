require "test_helper"

class TwoFactorAuthenticatableTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "two-factor-#{SecureRandom.hex(5)}@example.test",
      password: "password1234", first_name: "Two", last_name: "Factor", locale: "en")
  end

  test "enrollment requires the password and encrypts the pending secret" do
    assert_raises(User::InvalidTwoFactorPassword) { @user.begin_two_factor_setup!(password: "wrong") }
    assert_nil @user.reload.two_factor_pending_secret_ciphertext

    secret = @user.begin_two_factor_setup!(password: "password1234")
    assert_equal secret, @user.begin_two_factor_setup!(password: "password1234")
    refute_includes @user.two_factor_pending_secret_ciphertext, secret
    assert_not_predicate @user, :two_factor_enabled?
    assert_raises(User::InvalidTwoFactorCode) { @user.enable_two_factor!("invalid") }
    assert_not_predicate @user.reload, :two_factor_enabled?
  end

  test "confirmation encrypts the active secret and prevents TOTP replay" do
    secret, codes, used_code = enable_two_factor
    assert_predicate @user, :two_factor_enabled?
    assert_nil @user.two_factor_pending_secret_ciphertext
    refute_includes @user.two_factor_secret_ciphertext, secret
    assert_equal 10, codes.uniq.length
    assert_equal 10, @user.two_factor_recovery_codes_remaining
    codes.each { |code| refute_includes @user.two_factor_recovery_code_digests, code }
    assert_raises(User::InvalidTwoFactorCode) { @user.verify_two_factor_code!(code: used_code) }

    travel 31.seconds do
      next_code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
      assert @user.verify_two_factor_code!(code: next_code)
      assert_raises(User::InvalidTwoFactorCode) { @user.verify_two_factor_code!(code: next_code) }
    end
  end

  test "recovery codes are case insensitive single use and race safe" do
    _, codes = enable_two_factor
    stale_user = User.find(@user.id)
    code = codes.first.upcase.delete("-")
    assert @user.verify_two_factor_code!(recovery_code: code)
    assert_equal 9, @user.reload.two_factor_recovery_codes_remaining
    assert_raises(User::InvalidTwoFactorCode) { stale_user.verify_two_factor_code!(recovery_code: codes.first) }
    assert_raises(User::InvalidTwoFactorCode) { @user.verify_two_factor_code!(recovery_code: "invalid") }
    assert_equal 9, @user.reload.two_factor_recovery_codes_remaining
  end

  test "stale enrollment cannot replace an existing authenticator" do
    secret = @user.begin_two_factor_setup!(password: "password1234")
    stale_user = User.find(@user.id)
    @user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    ciphertext = @user.two_factor_secret_ciphertext

    assert_raises(User::InvalidTwoFactorCode) { stale_user.begin_two_factor_setup!(password: "password1234") }
    assert_raises(User::InvalidTwoFactorCode) { stale_user.enable_two_factor!("123456") }
    assert_equal ciphertext, @user.reload.two_factor_secret_ciphertext
  end

  test "disabling requires both password and a valid unused second factor" do
    _, codes = enable_two_factor
    assert_raises(User::InvalidTwoFactorPassword) do
      @user.disable_two_factor!(password: "wrong", recovery_code: codes.first)
    end
    assert_equal 10, @user.reload.two_factor_recovery_codes_remaining
    assert_raises(User::InvalidTwoFactorCode) { @user.disable_two_factor!(password: "password1234", code: "invalid") }
    assert_predicate @user.reload, :two_factor_enabled?

    @user.disable_two_factor!(password: "password1234", recovery_code: codes.first)
    assert_not_predicate @user.reload, :two_factor_enabled?
    assert_nil @user.two_factor_secret_ciphertext
    assert_empty @user.two_factor_recovery_code_digests
  end

  test "password changes do not remove two factor authentication" do
    enable_two_factor
    @user.update!(password: "new-password1234")
    assert_predicate @user.reload, :two_factor_enabled?
  end

  test "administrators retain their separate mandatory MFA" do
    @user.update!(system_role: "admin")
    assert_raises(User::InvalidTwoFactorCode) { @user.begin_two_factor_setup!(password: "password1234") }
    assert_not_predicate @user.reload, :two_factor_enabled?
  end

  test "session approval is bound to the current enrollment" do
    enable_two_factor
    session = @user.sessions.create!
    assert_not_predicate session, :two_factor_verified?
    session.mark_two_factor_verified!
    assert_predicate session, :two_factor_verified?
    @user.update!(two_factor_enabled_at: 1.second.from_now)
    assert_not_predicate session, :two_factor_verified?
  end

  private

  def enable_two_factor
    secret = @user.begin_two_factor_setup!(password: "password1234")
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    codes = @user.enable_two_factor!(code)
    [ secret, codes, code ]
  end
end
