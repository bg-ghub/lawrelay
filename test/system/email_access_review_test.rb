require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class EmailAccessReviewTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include MarketplaceTestFactory

  setup do
    @previous_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    @account = create_marketplace_account(prefix: "email-access-browser", verified: false, email_verified: false)
    @directory_email = @account.user.email_address
    profile_id = SecureRandom.uuid
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_profile_id: profile_id, directory_name: @account.user.full_name,
      directory_email: @directory_email, directory_checked_at: Time.current)
    @admin = User.create!(first_name: "Email", last_name: "Reviewer", email_address: "email-review-admin-#{SecureRandom.hex(5)}@example.test",
      password: "password1234", system_role: "admin", email_verified_at: Time.current, locale: "en")
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    @mfa_secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    @original_fetch = Directory::AdvocaatBeProfileLookup.instance_method(:fetch_html)
    html = <<~HTML
      <main id="main"><h1>#{ERB::Util.html_escape(@account.user.full_name)}</h1>
        <a href="mailto:#{ERB::Util.html_escape(@directory_email)}">Email</a></main>
    HTML
    Directory::AdvocaatBeProfileLookup.define_method(:fetch_html) { |_uri| html }
    Directory::AdvocaatBeProfileLookup.send(:private, :fetch_html)
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Capybara.reset_sessions!
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser.respond_to?(:execute_cdp)
    page.current_window.resize_to(1400, 1400)
    if @original_fetch
      Directory::AdvocaatBeProfileLookup.define_method(:fetch_html, @original_fetch)
      Directory::AdvocaatBeProfileLookup.send(:private, :fetch_html)
    end
    @previous_admin_id.nil? ? ENV.delete("LAWRELAY_ADMIN_USER_ID") : ENV["LAWRELAY_ADMIN_USER_ID"] = @previous_admin_id
    user_ids = [ @admin&.id, @account&.user&.id ].compact
    firm_ids = [ @account&.firm&.id ].compact
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Notification.where(user_id: user_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
    ActionMailer::Base.deliveries.clear
  end

  test "a member confirms a working email and an MFA-authenticated admin reviews the mismatch" do
    sign_in_member
    click_link I18n.t("email_access.link", locale: :en)
    assert_current_path email_access_request_path(locale: :en)

    working_email = "working-#{SecureRandom.hex(5)}@example.test"
    fill_in "Email you can access", with: working_email
    fill_in "Current password", with: "password1234"
    perform_enqueued_jobs do
      click_button "Request review"
      assert_current_path verification_status_path(locale: :en)
    end

    assert_text "Email review pending"
    assert_equal working_email, @account.user.reload.email_address
    assert @account.profile.reload.email_review_pending?
    assert @account.profile.directory_matched?
    assert_not @account.user.marketplace_verified?
    assert_equal [ working_email ], ActionMailer::Base.deliveries.flat_map(&:to)

    confirmation = ActionMailer::Base.deliveries.find { |mail| mail.to == [ working_email ] }
    confirmation_url = confirmation.text_part.body.decoded.lines.map(&:strip).find { |line| line.start_with?("http") }
    assert confirmation_url, "Expected a local captured confirmation link"
    visit URI(confirmation_url).request_uri
    click_button I18n.t("auth.email_verifications.review.submit", locale: :en)
    assert_current_path verification_status_path(locale: :en)
    assert_text "Email review pending"
    assert @account.user.reload.email_verified?
    assert_not @account.user.marketplace_verified?
    assert_nil @account.profile.reload.directory_email_verified_at

    Capybara.using_session(:email_access_admin) do
      sign_in_admin
      click_link "Review email"
      assert_current_path admin_email_review_path(@account.user, locale: :en)
      assert_text working_email
      assert_text @directory_email
      fill_in "Review note", with: "Synthetic independent firm contact check."
      check I18n.t("email_access.admin.identity_checked", locale: :en)
      perform_enqueued_jobs do
        click_button "Approve"
        assert_text "Email review approved."
      end
      assert @account.profile.reload.email_review_approved?
      assert @account.user.reload.marketplace_verified?
    end

    decision = ActionMailer::Base.deliveries.find { |mail| mail.subject == I18n.t("email_access.mailer.subject.approved", locale: :en) }
    assert_equal [ working_email ], decision&.to
    assert_not_includes decision.body.to_s, "Synthetic independent firm contact check."
    visit dashboard_path(locale: :en)
    assert_current_path dashboard_path(locale: :en)
  end

  test "email access and pending admin review fit small screens in all four languages" do
    sign_in_member
    %i[nl fr de en].each do |locale|
      resize_viewport(320)
      visit email_access_request_path(locale:)
      assert_selector "html[lang='#{locale}']"
      assert_no_text "Translation missing"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth")
      assert_field I18n.t("email_access.request.form.new_email", locale:)
      assert_field I18n.t("email_access.request.form.password", locale:)
      page.save_screenshot(Rails.root.join("tmp/screenshots/email-access-member-320.png").to_s) if locale == :nl
    end

    @account.profile.update!(email_review_status: "pending", email_review_email_address: @account.user.email_address,
      email_review_requested_at: 1.minute.ago, directory_checked_at: Time.current)
    Capybara.using_session(:email_access_admin) do
      sign_in_admin
      %i[nl fr de en].each do |locale|
        resize_viewport(320)
        [ admin_email_reviews_path(locale:), admin_email_review_path(@account.user, locale:) ].each do |path|
          visit path
          assert_selector "html[lang='#{locale}']"
          assert_no_text "Translation missing"
          assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth")
        end
        assert_button I18n.t("email_access.admin.approve", locale:), disabled: true
        assert_field I18n.t("email_access.admin.note", locale:)
        assert_text I18n.t("email_access.admin.not_ready", locale:)
        page.save_screenshot(Rails.root.join("tmp/screenshots/email-access-admin-320.png").to_s) if locale == :nl
      end
    end
  end

  test "a pending email review can retry an unavailable directory check without granting access" do
    @account.profile.update!(email_review_status: "pending", email_review_email_address: @account.user.email_address,
      email_review_requested_at: 1.minute.ago, directory_checked_at: 2.minutes.ago)
    AuditEvent.create!(auditable: @account.profile, actor_user: @account.user, firm: @account.firm,
      action: "verification.directory_lookup_failed", metadata: {
        status: "unavailable", identity_digest: @account.profile.directory_lookup_identity_digest
      })
    sign_in_member
    assert_text I18n.t("directory_feedback.failures.unavailable", locale: :en)
    assert_button I18n.t("directory_onboarding.status.retry", locale: :en)

    perform_enqueued_jobs do
      click_button I18n.t("directory_onboarding.status.retry", locale: :en)
      assert_current_path verification_status_path(locale: :en)
    end
    visit verification_status_path(locale: :en)
    assert @account.profile.reload.email_review_directory_ready?
    assert @account.profile.email_review_pending?
    assert_not @account.user.reload.marketplace_verified?
    assert_nil @account.profile.directory_email_verified_at
    assert_no_button I18n.t("directory_onboarding.status.retry", locale: :en)
    assert_no_text I18n.t("directory_feedback.failures.unavailable", locale: :en)
  end

  private

  def sign_in_member
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path verification_status_path(locale: :en)
  end

  def sign_in_admin
    visit admin_email_reviews_path(locale: :en)
    assert_current_path admin_login_path(locale: :en)
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    fill_in "mfa_code", with: ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now
    click_button I18n.t("mfa.challenge.submit", locale: :en)
    assert_current_path admin_email_reviews_path(locale: :en)
  end

  def resize_viewport(width)
    page.current_window.resize_to(width, 1000)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 1, mobile: false) if page.driver.browser.respond_to?(:execute_cdp)
  end
end
