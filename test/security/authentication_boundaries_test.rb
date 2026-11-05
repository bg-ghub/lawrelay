require "test_helper"
require_relative "../support/marketplace_test_factory"

class AuthenticationBoundariesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @account = create_marketplace_account(prefix: "auth-boundary")
  end

  test "directory confirmation rechecks token identity after a concurrent directory change" do
    user = @account.user
    profile = prepare_directory_profile
    token = Directory::ConfirmationToken.generate(profile)
    original = Directory::ConfirmationToken.method(:find_profile!)
    changed = false
    Directory::ConfirmationToken.define_singleton_method(:find_profile!) do |supplied|
      found = original.call(supplied)
      unless changed
        LawyerProfile.find(found.id).update!(directory_email: "new-official@example.test",
          directory_identity_digest: "new-directory-identity", directory_email_verified_at: nil)
        changed = true
      end
      found
    end

    post confirm_directory_verification_path(token:, locale: :en)

    assert changed
    assert_equal "new-official@example.test", profile.reload.directory_email
    assert_not profile.directory_email_verified?, "An old-address token must not confirm the newly loaded official address"
    assert_not user.reload.marketplace_verified?
  ensure
    Directory::ConfirmationToken.define_singleton_method(:find_profile!, original) if original
  end

  test "revoking an admin session during MFA enrollment prevents factor activation" do
    admin = synthetic_admin
    secret = admin.begin_admin_mfa_setup!
    sign_in_as(admin)
    session_id = Current.session.id
    with_admin_session_change(-> { Session.where(id: session_id).delete_all }) do
      post admin_mfa_setup_path(locale: :en), params: { mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now }
    end

    assert_not Session.exists?(session_id)
    assert_not admin.reload.admin_mfa_configured?, "A revoked password session must not activate an authenticator"
    assert_redirected_to admin_login_path(locale: :en)
  end

  test "admin enrollment rejects expiry suspension and role changes after initial authentication" do
    admin = synthetic_admin
    secret = admin.begin_admin_mfa_setup!
    pending = admin.admin_mfa_pending_secret_ciphertext
    changes = [
      -> { Current.session.update_columns(created_at: 16.minutes.ago, expires_at: 30.days.from_now) },
      -> { User.where(id: admin.id).update_all(suspended_at: Time.current) },
      -> { User.where(id: admin.id).update_all(system_role: "member") }
    ]

    changes.each do |change|
      admin.update!(system_role: "admin", suspended_at: nil)
      sign_in_as(admin)
      with_admin_session_change(change) do
        post admin_mfa_setup_path(locale: :en), params: { mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now }
      end

      assert_redirected_to admin_login_path(locale: :en)
      assert_predicate cookies[:session_id], :blank?
      assert_not admin.reload.admin_mfa_configured?
      assert_equal pending, admin.admin_mfa_pending_secret_ciphertext
    end
  end

  test "revoked admin enrollment cannot disclose a pending setup key" do
    admin = synthetic_admin
    sign_in_as(admin)
    with_admin_session_change(-> { Current.session.delete }) do
      get admin_mfa_setup_path(locale: :en)
    end

    assert_redirected_to admin_login_path(locale: :en)
    assert_nil admin.reload.admin_mfa_pending_secret_ciphertext
    assert_select "img.mfa-qr", count: 0
  end

  test "a revoked admin challenge cannot consume a valid authenticator code" do
    admin = synthetic_admin
    secret = admin.begin_admin_mfa_setup!
    admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    admin.update!(admin_mfa_last_verified_at: 1.minute.ago)
    last_verified = admin.admin_mfa_last_verified_at
    sign_in_as(admin)
    with_admin_session_change(-> { Current.session.delete }) do
      post admin_mfa_challenge_path(locale: :en), params: { mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now }
    end

    assert_redirected_to admin_login_path(locale: :en)
    assert_equal last_verified, admin.reload.admin_mfa_last_verified_at
    assert_empty admin.sessions
  end

  test "replaying a confirmed directory token does not refresh confirmation or repeat its audit" do
    profile = prepare_directory_profile
    token = Directory::ConfirmationToken.generate(profile)
    post confirm_directory_verification_path(token:, locale: :en)
    confirmed_at = profile.reload.directory_email_verified_at
    assert confirmed_at.present?
    audit_count = AuditEvent.where(auditable: profile).count

    travel 1.minute do
      post confirm_directory_verification_path(token:, locale: :en)
    end

    assert_redirected_to new_session_path(locale: :en)
    assert_equal confirmed_at, profile.reload.directory_email_verified_at
    assert_equal audit_count, AuditEvent.where(auditable: profile).count
    assert_not @account.user.reload.marketplace_verified?
  end

  test "an already confirmed directory inbox can finish an interrupted activation only once" do
    profile = prepare_directory_profile
    user = @account.user
    user.update!(email_address: profile.directory_email)
    user.update!(email_verified_at: Time.current)
    profile.update!(professional_email: user.email_address, directory_email_verified_at: Time.current,
      verification_status: "pending", verified_at: nil)
    @account.firm.update!(verification_status: "pending", verified_at: nil)
    confirmed_at = profile.reload.directory_email_verified_at
    token = Directory::ConfirmationToken.generate(profile)

    post confirm_directory_verification_path(token:, locale: :en)

    assert user.reload.marketplace_verified?
    assert_equal confirmed_at, profile.reload.directory_email_verified_at
    audit_count = AuditEvent.where(auditable: profile).count
    travel 1.minute do
      post confirm_directory_verification_path(token:, locale: :en)
    end
    assert_equal audit_count, AuditEvent.where(auditable: profile).count
    assert_equal confirmed_at, profile.reload.directory_email_verified_at
  end

  test "a valid CSRF token still cannot authorize a cross-origin MFA enrollment" do
    original_protection = TwoFactorAuthenticationsController.allow_forgery_protection
    TwoFactorAuthenticationsController.allow_forgery_protection = true
    sign_in_as(@account.user)
    get two_factor_authentication_path(locale: :en)
    token = Nokogiri::HTML(response.body).at_css("meta[name='csrf-token']")&.[]("content")
    assert token.present?

    post begin_setup_two_factor_authentication_path(locale: :en),
      params: { current_password: "password1234", authenticity_token: token },
      headers: { "Origin" => "https://unrelated.example" }

    assert_response :unprocessable_content
    assert_nil @account.user.reload.two_factor_pending_secret_ciphertext
  ensure
    TwoFactorAuthenticationsController.allow_forgery_protection = original_protection
  end

  test "email and password reset tokens cannot cross their intended purposes" do
    user = @account.user
    user.update!(email_verified_at: nil)
    original_digest = user.password_digest
    email_token = user.email_verification_token
    reset_token = user.password_reset_token

    patch password_path(token: email_token, locale: :en),
      params: { password: "replacement-password", password_confirmation: "replacement-password" }
    assert_redirected_to new_password_path(locale: :en)
    assert_equal original_digest, user.reload.password_digest

    post confirm_email_verification_path(token: reset_token, locale: :en)
    assert_redirected_to new_session_path(locale: :en)
    assert_not user.reload.email_verified?
  end

  private

  def synthetic_admin
    User.create!(email_address: "admin-boundary-#{SecureRandom.hex(4)}@example.test", password: "password1234",
      first_name: "Synthetic", last_name: "Administrator", system_role: "admin", locale: "en", email_verified_at: Time.current)
  end

  def prepare_directory_profile
    @account.user.update!(email_verified_at: nil)
    profile_id = SecureRandom.uuid
    @account.profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: @account.user.full_name, directory_email: "old-official@example.test",
      directory_checked_at: Time.current, directory_identity_digest: "old-directory-identity")
    @account.profile
  end

  def with_admin_session_change(change)
    original = Admin::MfaController.instance_method(:redirect_verified_session)
    Admin::MfaController.define_method(:redirect_verified_session) do
      original.bind_call(self)
      change.call unless performed?
    end
    Admin::MfaController.send(:private, :redirect_verified_session)
    yield
  ensure
    Admin::MfaController.define_method(:redirect_verified_session, original)
    Admin::MfaController.send(:private, :redirect_verified_session)
  end
end
