require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class RegistryStatusLayoutTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @previous_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    @admin = User.create!(first_name: "Registry", last_name: "Reviewer", email_address: "registry-layout-admin-#{SecureRandom.hex(5)}@example.test",
      password: "password1234", system_role: "admin", email_verified_at: Time.current)
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    @secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(@secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    visit admin_registry_statuses_path(locale: :en)
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    fill_in "mfa_code", with: ROTP::TOTP.new(@secret, issuer: "LawRelay").now
    click_button "Continue"
    assert_current_path admin_registry_statuses_path(locale: :en)
  end

  teardown do
    Capybara.reset_sessions!
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1400)
    ENV["LAWRELAY_ADMIN_USER_ID"] = @previous_admin_id
    AuditEvent.where(actor_user_id: @admin&.id).delete_all
    @check&.destroy!
    @run&.destroy!
    @account&.user&.destroy!
    @account&.firm&.destroy!
    @admin&.destroy!
  end

  test "long registry headings fit narrow and desktop viewports in all languages" do
    assert_registry_layout
  end

  test "registry results and member links fit the same responsive layout" do
    @account = create_marketplace_account(prefix: "registry-layout")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @account.user.full_name, directory_email: @account.user.email_address)
    target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == @account.profile.id }
    @check = RegistryStatusCheck.new(source: "directory", target_digest: target.digest, lawyer_profile: @account.profile)
    @check.record_result!(outcome: "not_listed", checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    @run = RegistryStatusRun.create!(run_on: Date.current, status: "completed", completed_at: Time.current, checked_count: 1)
    assert_registry_layout
  end

  private

  def assert_registry_layout
    %i[nl fr de en].each do |locale|
      [ 320, 390, 768, 1440 ].each do |width|
        page.current_window.resize_to(width, 1000)
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 1, mobile: false)
        visit admin_registry_statuses_path(locale:)
        assert_selector "h1", text: I18n.t("registry_status.title", locale:), exact_text: true
        assert_equal width, page.evaluate_script("window.innerWidth")
        assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width, "Registry page overflows in #{locale} at #{width}px"
        assert_no_text(/translation missing/i)
        if @check
          assert_selector ".registry-status-check", count: 1
          assert_selector ".registry-status-check a[href='#{admin_user_path(@account.user, locale:)}']", text: @account.user.full_name
        end
        page.save_screenshot(Rails.root.join("tmp/ux-browsing-experience/registry-fixed-#{locale}-#{width}.png")) if locale == :nl && width == 320
      end
    end
  end
end
