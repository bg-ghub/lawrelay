require "test_helper"
require_relative "../support/marketplace_test_factory"

class AdminHostRoutingTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST", "APP_PROTOCOL", "LAWRELAY_ADMIN_USER_ID")
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["ADMIN_HOST"] = "admin.lawrelay.example"
    ENV["APP_PROTOCOL"] = "https"
    @admin = create_marketplace_account(prefix: "hostadmin", system_role: "admin").user
    @admin.update!(password: "admin-password1234")
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    @member = create_marketplace_account(prefix: "hostmember")
    host! "admin.lawrelay.example"
    https!
  end

  teardown do
    %w[APP_HOST ADMIN_HOST APP_PROTOCOL LAWRELAY_ADMIN_USER_ID].each do |key|
      @previous_environment.key?(key) ? ENV[key] = @previous_environment[key] : ENV.delete(key)
    end
  end

  test "admin roots and member sign-in open localized administrator login" do
    get "/"
    assert_redirected_to admin_users_path(locale: :nl)

    I18n.available_locales.each do |locale|
      get root_path(locale: locale)
      assert_redirected_to admin_users_path(locale: locale)
      follow_redirect!
      assert_redirected_to admin_login_path(locale: locale)
      follow_redirect!
      assert_response :success
      assert_select "input[name='password'][type='password']"
      assert_select ".product-bar, .primary-nav, .site-footer", count: 0
      assert_select ".language-menu"
      assert_select ".footer-project__version", text: /#{Regexp.escape(LawRelay::VERSION)}/
      assert_select ".footer-project__source[href='https://github.com/bg-ghub/lawrelay']"
      assert_select ".admin-site-header a[href='https://lawrelay.example/#{locale}']"

      get new_session_path(locale: locale)
      assert_redirected_to admin_login_path(locale: locale)
    end
  end

  test "public and member pages on the admin host redirect to the trusted main host" do
    %w[privacy terms registration/new dashboard assignments settings].each do |path|
      get "/fr/#{path}"

      assert_response :see_other
      assert_redirected_to "https://lawrelay.example/fr/#{path}"
    end

    get "/en/assignments", params: { q: "court" }
    assert_redirected_to "https://lawrelay.example/en/assignments?q=court"

    assert_no_difference [ "Assignment.count", "Session.count" ] do
      post "/en/assignments", params: { assignment: { title: "Should not be created here" } }
    end
    assert_redirected_to "https://lawrelay.example/en"
  end

  test "a correct administrator password still requires MFA and sets a host-only session cookie" do
    secret = configure_mfa
    get admin_users_path(locale: :en)
    post admin_login_path(locale: :en), params: { password: "admin-password1234" }

    assert_redirected_to admin_users_path(locale: :en)
    session_cookie = Array(response.headers["set-cookie"]).find { |cookie| cookie.start_with?("session_id=") }
    assert session_cookie
    assert_no_match(/;\s*domain=/i, session_cookie)
    assert_match(/HttpOnly/i, session_cookie)
    follow_redirect!
    assert_redirected_to admin_mfa_challenge_path(locale: :en)
    follow_redirect!
    assert_response :success

    post admin_mfa_challenge_path(locale: :en), params: { mfa_code: ROTP::TOTP.new(secret, issuer: "LawRelay").now }
    assert_redirected_to admin_users_path(locale: :en)
    follow_redirect!
    assert_response :success
    assert_select ".admin-navigation"

    delete session_path(locale: :en)
    assert_redirected_to admin_login_path(locale: :en)
    get admin_users_path(locale: :en)
    assert_redirected_to admin_login_path(locale: :en)
  end

  test "unauthenticated MFA requests return directly to administrator login" do
    get admin_mfa_setup_path(locale: :fr)
    assert_redirected_to admin_login_path(locale: :fr)

    get admin_mfa_challenge_path(locale: :de)
    assert_redirected_to admin_login_path(locale: :de)
  end

  test "member credentials and a copied member session never grant administrator access" do
    assert_no_difference "Session.count" do
      post session_path(locale: :en), params: { email_address: @member.user.email_address, password: "password1234" }
      assert_redirected_to admin_login_path(locale: :en)
      post admin_login_path(locale: :en), params: { password: "password1234" }
      assert_response :unprocessable_content
    end

    sign_in_as(@member.user, admin_mfa: true)
    get admin_users_path(locale: :en)
    assert_redirected_to admin_login_path(locale: :en)
    assert_not @member.user.reload.system_admin?
  end

  test "administrator recovery stays on the admin host and keeps MFA after a password reset" do
    configure_mfa
    @admin.sessions.create!
    get new_password_path(locale: :en, email_address: @admin.email_address)
    assert_response :success
    assert_select "a[href='#{admin_login_path(locale: :en)}']"
    assert_select "input[type='email'][value='#{@admin.email_address}']"

    post passwords_path(locale: :en), params: { email_address: @admin.email_address }
    assert_enqueued_email_with PasswordsMailer, :reset, args: [ @admin ]
    assert_redirected_to admin_login_path(locale: :en)

    token = @admin.password_reset_token
    get edit_password_path(token: token, locale: :en)
    assert_response :success
    put password_path(token: token, locale: :en), params: {
      password: "replacement-password1234", password_confirmation: "replacement-password1234"
    }
    assert_redirected_to admin_login_path(locale: :en)
    assert_empty @admin.reload.sessions
    assert_predicate @admin, :admin_mfa_configured?

    post admin_login_path(locale: :en), params: { password: "replacement-password1234" }
    follow_redirect!
    assert_redirected_to admin_mfa_challenge_path(locale: :en)
  end

  test "account security emails use their configured host and preserve the locale" do
    I18n.available_locales.each do |locale|
      @admin.update!(locale: locale)
      @member.user.update!(locale: locale)
      [ PasswordsMailer.reset(@admin), EmailVerificationMailer.verify(@admin) ].each do |message|
        assert_includes message.text_part.body.decoded, "https://admin.lawrelay.example/#{locale}/"
      end
      [ PasswordsMailer.reset(@member.user), EmailVerificationMailer.verify(@member.user) ].each do |message|
        assert_includes message.text_part.body.decoded, "https://lawrelay.example/#{locale}/"
        assert_not_includes message.text_part.body.decoded, "admin.lawrelay.example"
      end
    end
  end

  test "administrator email change and confirmation remain usable on the admin host" do
    sign_in_as(@admin, admin_mfa: true)
    get email_change_path(locale: :en)
    assert_response :success

    post email_change_path(locale: :en), params: {
      email_change: { email_address: "changed-host-admin@example.test", current_password: "admin-password1234" }
    }
    assert_redirected_to admin_users_path(locale: :en)
    @admin.reload
    assert_equal "changed-host-admin@example.test", @admin.email_address
    assert_not @admin.email_verified?

    token = @admin.email_verification_token
    get email_verification_path(token: token, locale: :en)
    assert_response :success
    post confirm_email_verification_path(token: token, locale: :en)
    assert_redirected_to admin_users_path(locale: :en)
    assert_predicate @admin.reload, :email_verified?
  end

  test "member verification on the admin host returns to the main confirmation page without confirming" do
    @member.user.update!(email_verified_at: nil)
    token = @member.user.email_verification_token

    post confirm_email_verification_path(token: token, locale: :fr)

    assert_redirected_to "https://lawrelay.example/fr/email-verification/#{token}"
    assert_not @member.user.reload.email_verified?
  end

  test "invalid administrator email verification returns directly to administrator login" do
    get email_verification_path(token: "invalid-verification", locale: :fr)

    assert_redirected_to admin_login_path(locale: :fr)
    follow_redirect!
    assert_response :success
    assert_includes response.body, I18n.t("auth.email_verification.invalid", locale: :fr)
  end

  test "health endpoints work and admin pages are excluded from search indexing" do
    get "/up"
    assert_response :success
    get "/ready"
    assert_response :success
    get "/robots.txt"
    assert_response :success
    assert_equal "User-agent: *\nDisallow: /\n", response.body
    get "/sitemap.xml"
    assert_redirected_to "https://lawrelay.example/sitemap.xml"
    get admin_login_path(locale: :en)
    assert_select "meta[name='robots'][content='noindex,nofollow']"
  end

  test "main-site member login and legacy administrator paths remain compatible" do
    host! "lawrelay.example"
    get new_session_path(locale: :en)
    assert_response :success
    assert_select "input[type='email']"
    assert_select "a[href='https://admin.lawrelay.example/en/admin/login']"

    post session_path(locale: :en), params: { email_address: @member.user.email_address, password: "password1234" }
    assert_redirected_to dashboard_path(locale: :en)
    delete session_path(locale: :en)
    assert_redirected_to new_session_path(locale: :en)

    get admin_login_path(locale: :en)
    assert_response :success
    post admin_login_path(locale: :en), params: { password: "admin-password1234" }
    assert_redirected_to admin_users_path(locale: :en)
    follow_redirect!
    assert_redirected_to admin_mfa_setup_path(locale: :en)
  end

  private

  def configure_mfa
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    secret
  end
end
