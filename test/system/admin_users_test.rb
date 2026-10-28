require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AdminUsersTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    token = SecureRandom.hex(6)
    @admin = User.create!(
      first_name: "Operator", last_name: "Test", email_address: "admin-system-#{token}@example.test",
      password: "password1234", system_role: "admin", email_verified_at: Time.current, locale: "en"
    )
    @mfa_secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    @account = create_marketplace_account(prefix: "alex")
    @account.user.update!(first_name: "Alex", last_name: "Peeters")
    @account.firm.update!(name: "Peeters Advocaten")
  end

  teardown do
    Capybara.reset_sessions!
    if page.driver.browser.respond_to?(:execute_cdp)
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    page.current_window.resize_to(1400, 1400)
    user_ids = [ @admin&.id, @account&.user&.id ].compact
    firm_ids = [ @account&.firm&.id ].compact
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
  end

  test "an operator without a firm signs in through MFA and manages account details" do
    sign_in_admin
    assert_nil @admin.primary_firm
    assert_nil @admin.lawyer_profile
    assert_selector "h1", text: "Users"

    fill_in "q", with: @account.user.email_address
    within(".admin-users-filter-form") { click_button "Search" }
    assert_selector ".admin-user-row", count: 1
    find(".admin-user-manage").click
    assert_current_path admin_user_path(@account.user, locale: :en)

    within("form[action='#{admin_user_path(@account.user, locale: :en)}']") do
      select "Français", from: "user_locale"
      click_button "Save account"
    end
    assert_text "Account details saved."
    assert_equal "fr", @account.user.reload.locale
    assert @account.user.marketplace_verified?

    Capybara.using_session(:managed_member) { sign_in_member }
    assert_operator @account.user.sessions.count, :>, 0
    within("form[action='#{admin_user_path(@account.user, locale: :en)}']") do
      fill_in "user_first_name", with: "Updated"
      click_button "Save account"
    end
    assert_text "Account details saved."
    assert_equal "Updated", @account.user.reload.first_name
    assert_equal "pending", @account.profile.reload.verification_status
    assert @account.firm.reload.verified?
    assert_empty @account.user.sessions
    Capybara.using_session(:managed_member) do
      visit dashboard_path(locale: :en)
      assert_current_path new_session_path(locale: :en)
    end
  end

  test "suspension restoration and session revocation work without changing professional approval" do
    sign_in_admin
    Capybara.using_session(:managed_member) { sign_in_member }
    visit admin_user_path(@account.user, locale: :en)

    submit_access_action(:suspend, "Synthetic access review", "Suspend account")
    assert_text "The account is suspended"
    assert @account.user.reload.suspended?
    assert @account.profile.reload.verified?
    assert @account.firm.reload.verified?
    Capybara.using_session(:managed_member) do
      visit dashboard_path(locale: :en)
      assert_current_path new_session_path(locale: :en)
      fill_in "email_address", with: @account.user.email_address
      fill_in "password", with: "password1234"
      find("form.assignment-form input[type='submit']").click
      assert_current_path new_session_path(locale: :en)
    end

    submit_access_action(:restore, "Synthetic review completed", "Restore access")
    assert_text "Account access restored."
    assert @account.user.reload.marketplace_verified?
    Capybara.using_session(:managed_member) { sign_in_member }
    assert_operator @account.user.sessions.count, :>, 0

    submit_access_action(:revoke_sessions, "Synthetic session reset", "Sign out all sessions")
    assert_text "All sessions for this account are signed out."
    assert @account.user.reload.active?
    assert @account.profile.reload.verified?
    assert_empty @account.user.sessions
    Capybara.using_session(:managed_member) do
      visit dashboard_path(locale: :en)
      assert_current_path new_session_path(locale: :en)
    end
  end

  test "user management is labelled and fits narrow screens in all four languages" do
    sign_in_admin
    %i[nl fr de en].each do |locale|
      [ 320, 1100, 1280, 1366 ].each do |width|
        resize_viewport(width, 900)
        visit admin_users_path(locale:)
        assert_selector "html[lang='#{locale}']"
        assert_equal 1, all("main", visible: :all).size
        assert_no_text "Translation missing"
        assert_page_fits(width, locale)
        all(".admin-users-filter-form input:not([type='hidden']):not([type='submit']), .admin-users-filter-form select").each do |field|
          assert field.native.accessible_name.present?, "Unlabelled filter #{field[:id]}"
        end

        visit admin_user_path(@account.user, locale:)
        assert_no_text "Translation missing"
        assert_page_fits(width, locale)
        all(".admin-users-page input:not([type='hidden']):not([type='submit']), .admin-users-page select, .admin-users-page textarea").each do |field|
          assert field.native.accessible_name.present?, "Unlabelled account control #{field[:id]}"
        end
      end
    end

    resize_viewport(1280, 1000)
    visit admin_users_path(locale: :en)
    save_screenshot(Rails.root.join("tmp/screenshots/admin-users-desktop.png"))
    resize_viewport(390, 844)
    visit admin_user_path(@account.user, locale: :fr)
    save_screenshot(Rails.root.join("tmp/screenshots/admin-user-mobile.png"))

    visit admin_user_path(@admin, locale: :en)
    assert_text "Administrator accounts are read-only here."
    assert_no_selector ".admin-user-access-form"
    assert_no_selector "#user_email_address"
  end

  private

  def sign_in_admin
    visit admin_users_path(locale: :en)
    assert_current_path new_session_path(locale: :en)
    fill_in "email_address", with: @admin.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    fill_in "mfa_code", with: ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now
    click_button "Continue"
    assert_current_path admin_users_path(locale: :en)
  end

  def sign_in_member
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  def submit_access_action(action, reason, button)
    path = public_send("#{action}_admin_user_path", @account.user, locale: :en)
    within("form[action='#{path}']") do
      fill_in "Internal reason", with: reason
      click_button button
    end
  end

  def assert_page_fits(width, locale)
    assert_equal width, page.evaluate_script("window.innerWidth"), "Requested viewport was not applied"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth"), "User management overflows at #{width}px in #{locale}"
  end

  def resize_viewport(width, height)
    page.current_window.resize_to(width, height)
    if page.driver.browser.respond_to?(:execute_cdp)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height:, deviceScaleFactor: 1, mobile: false)
    end
  end
end
