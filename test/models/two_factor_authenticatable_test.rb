require "test_helper"

class TwoFactorAuthenticatableTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email_address: "two-factor-#{SecureRandom.hex(5)}@example.test",
      password: "password1234", first_name: "Two", last_name: "Factor", locale: "en", email_verified_at: Time.current)
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

  test "unconfirmed signup cannot begin or enable an authenticator" do
    @user.update!(email_verified_at: nil)
    assert_raises(User::UnverifiedTwoFactorOwnership) { @user.begin_two_factor_setup!(password: "password1234") }
    assert_nil @user.reload.two_factor_pending_secret_ciphertext

    legacy_secret = ROTP::Base32.random_base32
    @user.update!(two_factor_pending_secret_ciphertext: User.two_factor_encryptor.encrypt_and_sign(legacy_secret))
    assert_nil @user.two_factor_pending_secret
    assert_raises(User::UnverifiedTwoFactorOwnership) do
      @user.enable_two_factor!(ROTP::TOTP.new(legacy_secret, issuer: "LawRelay").now)
    end
    assert_not_predicate @user.reload, :two_factor_enabled?
  end

  test "a pending key cannot survive an email ownership change even after reconfirmation" do
    old_secret = @user.begin_two_factor_setup!(password: "password1234")
    @user.update!(email_address: "changed-two-factor@example.test")
    assert_nil @user.two_factor_pending_secret
    @user.update!(email_verified_at: Time.current)
    assert_nil @user.two_factor_pending_secret
    assert_raises(User::InvalidTwoFactorCode) do
      @user.enable_two_factor!(ROTP::TOTP.new(old_secret, issuer: "LawRelay").now)
    end
    refute_equal old_secret, @user.begin_two_factor_setup!(password: "password1234")
  end

  test "password recovery invalidates a pending key without weakening an active factor" do
    old_secret = @user.begin_two_factor_setup!(password: "password1234")
    @user.update!(password: "new-password1234")
    assert_nil @user.two_factor_pending_secret
    refute_equal old_secret, @user.begin_two_factor_setup!(password: "new-password1234")
  end

  test "legacy pending keys are replaced while legacy active authenticators remain valid" do
    legacy_secret = ROTP::Base32.random_base32
    legacy_ciphertext = User.two_factor_encryptor.encrypt_and_sign(legacy_secret)
    @user.update!(two_factor_pending_secret_ciphertext: legacy_ciphertext)
    assert_nil @user.two_factor_pending_secret
    refute_equal legacy_secret, @user.begin_two_factor_setup!(password: "password1234")

    @user.update!(two_factor_pending_secret_ciphertext: nil, two_factor_secret_ciphertext: legacy_ciphertext,
      two_factor_enabled_at: 1.day.ago, email_verified_at: nil)
    assert_predicate @user, :two_factor_enabled?
    assert @user.verify_two_factor_code!(code: ROTP::TOTP.new(legacy_secret, issuer: "LawRelay").now)
  end

  test "audited manual approval permits enrollment and revoked approval invalidates its pending key" do
    @user.update!(email_verified_at: nil)
    firm = Firm.create!(name: Firm::INTERNAL_WORKSPACE_NAME)
    @user.memberships.create!(firm: firm, role: "owner")
    profile_id = SecureRandom.uuid
    profile = @user.create_lawyer_profile!(bar_association: "OVB", bar_number: "MFA-#{SecureRandom.hex(5)}",
      directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: @user.full_name, directory_email: @user.email_address, directory_checked_at: Time.current)
    admin = users(:one)
    admin.update!(system_role: "admin")
    admin_secret = admin.begin_admin_mfa_setup!
    admin.enable_admin_mfa!(ROTP::TOTP.new(admin_secret, issuer: "LawRelay").now)
    approval = Admin::ManualActivation.call(user: @user, actor: admin,
      note: "Synthetic ownership reviewed", identity_digest: profile.email_review_current_identity_digest)
    assert approval.success?
    assert_predicate @user.reload, :two_factor_enrollment_allowed?
    secret = @user.begin_two_factor_setup!(password: "password1234")
    profile.update_columns(manual_activation_approved_at: nil)
    assert_nil @user.two_factor_pending_secret
    assert_raises(User::UnverifiedTwoFactorOwnership) { @user.enable_two_factor!(ROTP::TOTP.new(secret, issuer: "LawRelay").now) }
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

  test "password and email changes do not remove an already trusted authenticator" do
    _, codes = enable_two_factor
    @user.update!(password: "new-password1234", email_address: "pending-two-factor@example.test")
    assert_nil @user.email_verified_at
    assert_predicate @user.reload, :two_factor_enabled?
    assert @user.verify_two_factor_code!(recovery_code: codes.first)
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
