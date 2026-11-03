require "test_helper"

class AdminMfaTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(
      email_address: "mfa-admin-#{SecureRandom.hex(4)}@example.test",
      password: "password1234",
      first_name: "Mfa",
      last_name: "Admin",
      locale: "en",
      system_role: "admin",
      email_verified_at: Time.current
    )
  end

  test "encrypts the TOTP secret and rejects replayed codes" do
    secret = @admin.begin_admin_mfa_setup!
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now

    refute_includes @admin.admin_mfa_pending_secret_ciphertext, secret
    @admin.enable_admin_mfa!(code)

    assert_predicate @admin, :admin_mfa_configured?
    assert_nil @admin.admin_mfa_pending_secret_ciphertext
    assert_raises(User::InvalidAdminMfaCode) { @admin.verify_admin_mfa_code!(code) }
  end

  test "admin sessions and MFA expire at the fifteen minute boundary" do
    freeze_time do
      session = @admin.sessions.create!
      session.mark_admin_mfa_verified!
      deadline = 15.minutes.from_now

      assert_equal deadline, session.expires_at
      assert_not session.expired?(at: deadline - 1.second)
      assert session.admin_mfa_verified?(at: deadline - 1.second)
      assert session.expired?(at: deadline)
      assert_not session.admin_mfa_verified?(at: deadline)
    end
  end

  test "legacy admin sessions expire despite a long cookie and fresh MFA" do
    session = @admin.sessions.create!
    session.update_columns(created_at: 16.minutes.ago, expires_at: 30.days.from_now)
    session.mark_admin_mfa_verified!

    assert_predicate session, :expired?
    assert_not_predicate session, :admin_mfa_verified?
  end

  test "activity and fresh MFA cannot extend the admin session deadline" do
    freeze_time do
      session = @admin.sessions.create!
      deadline = session.expires_at
      session.update_columns(last_seen_at: 16.minutes.ago)
      session.record_activity!(at: 14.minutes.from_now)
      session.mark_admin_mfa_verified!(at: 14.minutes.from_now)

      assert_equal 14.minutes.from_now, session.reload.last_seen_at
      assert_equal deadline, session.expires_at
      assert session.expired?(at: deadline)
      assert_not session.admin_mfa_verified?(at: deadline)
    end
  end

  test "ordinary member sessions retain their thirty day lifetime" do
    freeze_time do
      session = users(:one).sessions.create!

      assert_equal 30.days.from_now, session.expires_at
      assert_not session.expired?(at: 15.minutes.from_now)
      assert session.expired?(at: 30.days.from_now)
    end
  end

  test "configured MFA requires an explicit reset before enrollment can restart" do
    secret = @admin.begin_admin_mfa_setup!
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    @admin.enable_admin_mfa!(code)
    original_ciphertext = @admin.admin_mfa_secret_ciphertext

    assert_raises(User::InvalidAdminMfaCode) { @admin.begin_admin_mfa_setup! }
    assert_raises(User::InvalidAdminMfaCode) { @admin.enable_admin_mfa!(code) }
    assert_equal original_ciphertext, @admin.reload.admin_mfa_secret_ciphertext
    assert_nil @admin.admin_mfa_pending_secret_ciphertext

    @admin.reset_admin_mfa!
    new_secret = @admin.begin_admin_mfa_setup!
    assert_not_equal secret, new_secret
    @admin.enable_admin_mfa!(ROTP::TOTP.new(new_secret, issuer: "LawRelay").now)
    assert_predicate @admin, :admin_mfa_configured?
  end

  test "a stale enrollment cannot replace MFA enabled by another request" do
    secret = @admin.begin_admin_mfa_setup!
    stale_admin = User.find(@admin.id)
    code = ROTP::TOTP.new(secret, issuer: "LawRelay").now
    @admin.enable_admin_mfa!(code)
    original_ciphertext = @admin.admin_mfa_secret_ciphertext

    assert_raises(User::InvalidAdminMfaCode) { stale_admin.enable_admin_mfa!(code) }
    assert_raises(User::InvalidAdminMfaCode) { stale_admin.begin_admin_mfa_setup! }
    assert_equal original_ciphertext, @admin.reload.admin_mfa_secret_ciphertext
    assert_nil @admin.admin_mfa_pending_secret_ciphertext
  end
end
