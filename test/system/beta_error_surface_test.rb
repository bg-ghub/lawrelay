require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class BetaErrorSurfaceTest < ApplicationSystemTestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  LOCALES = %i[nl fr de en].freeze

  teardown do
    Capybara.reset_sessions!
    clear_enqueued_jobs
    clear_performed_jobs
    if page.driver.browser.respond_to?(:execute_cdp)
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
    page.current_window.resize_to(1400, 1400)
    remove_surface_records
  end

  test "invalid confirmation and reset links give localized recovery screens at mobile width" do
    resize_viewport(390)
    LOCALES.each do |locale|
      [
        [ email_verification_path(token: "invalid-email-token", locale:), new_session_path(locale:), "auth.email_verification.invalid" ],
        [ directory_verification_path(token: "invalid-directory-token", locale:), new_session_path(locale:), "directory_mail.notices.invalid" ],
        [ edit_password_path(token: "invalid-reset-token", locale:), new_password_path(locale:), "auth.passwords.invalid" ]
      ].each do |path, destination, message|
        visit path
        assert_current_path destination
        assert_selector ".flash-message--alert", text: I18n.t(message, locale:)
        assert_localized_layout(locale)
        assert_selector "form.assignment-form"
      end
    end
  end

  test "expired email and directory links cannot activate an account in any locale" do
    account = surface_account("expired", verified: false, email_verified: false)
    profile_id = SecureRandom.uuid
    account.profile.update!(
      directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: account.user.full_name,
      directory_email: "listed-#{SecureRandom.hex(5)}@example.test",
      directory_checked_at: Time.current,
      directory_identity_digest: SecureRandom.hex(32)
    )
    email_token = account.user.email_verification_token
    directory_token = Directory::ConfirmationToken.generate(account.profile)
    resize_viewport(390)

    travel 49.hours do
      LOCALES.each do |locale|
        visit email_verification_path(token: email_token, locale:)
        assert_current_path new_session_path(locale:)
        assert_selector ".flash-message--alert", text: I18n.t("auth.email_verification.invalid", locale:)
        assert_localized_layout(locale)

        visit directory_verification_path(token: directory_token, locale:)
        assert_current_path new_session_path(locale:)
        assert_selector ".flash-message--alert", text: I18n.t("directory_mail.notices.invalid", locale:)
        assert_localized_layout(locale)
      end
    end

    assert_not account.user.reload.email_verified?
    assert_not account.profile.reload.directory_email_verified?
    assert_not account.user.marketplace_verified?
  end

  test "anonymous and pending members keep localized marketplace guards and recovery access" do
    owner = surface_account("guard-owner")
    pending = surface_account("guard-pending", verified: false, email_verified: false)
    assignment = create_assignment_for(owner, title: "Synthetic guarded assignment")

    LOCALES.each do |locale|
      Capybara.reset_sessions!
      [ dashboard_path(locale:), assignments_path(locale:), new_assignment_path(locale:),
        assignment_path(assignment, locale:), settings_path(locale:), notifications_path(locale:),
        new_privacy_request_path(locale:), two_factor_authentication_path(locale:) ].each do |path|
        visit path
        assert_current_path new_session_path(locale:)
        assert_localized_layout(locale)
        assert_no_text assignment.title
      end

      Capybara.reset_sessions!
      sign_in_member(pending.user, locale:)
      [ dashboard_path(locale:), assignments_path(locale:), new_assignment_path(locale:),
        assignment_path(assignment, locale:) ].each do |path|
        visit path
        assert_current_path verification_status_path(locale:)
        assert_localized_layout(locale)
        assert_no_text assignment.title
      end

      [ settings_path(locale:), privacy_requests_path(locale:), new_privacy_request_path(locale:) ].each do |path|
        visit path
        assert_current_path path
        assert_localized_layout(locale)
      end
    end
  end

  test "legal tasks validate required language and deadline order while the indicative price stays optional" do
    LOCALES.each do |locale|
      Capybara.reset_sessions!
      account = surface_account("legal-#{locale}")
      sign_in_member(account.user, locale:)
      resize_viewport(390)
      visit new_assignment_path(locale:)
      find("label.kind-option", text: I18n.t("marketplace.kinds.legal_task", locale:)).click
      title = "Synthetic legal task #{locale} #{SecureRandom.hex(4)}"
      fill_in "assignment_title", with: title
      fill_in "assignment_description", with: "A fictional bounded legal task without client or case data."
      choose_searchable_option("assignment_practice_area", value: I18n.t("marketplace.practice_areas.employment", locale:))
      choose_searchable_option("assignment_legal_subtype", value: "advice")
      set_datetime("assignment_response_deadline_at", 3.days.from_now)
      set_datetime("assignment_execution_deadline", 2.days.from_now)
      fill_in "assignment_invoice_address_line_1", with: "Test Street 1"
      fill_in "assignment_invoice_postal_code", with: "1000"
      fill_in "assignment_invoice_city", with: "Brussels"
      find("#assignment_content_rules_accepted").check
      assert_field "assignment_fee_cents", with: ""
      assert_no_selector "#assignment_fee_cents[required]"
      assert_localized_layout(locale)

      count = account.firm.assignments.count
      click_button I18n.t("marketplace.form.submit", locale:)
      assert_equal "assignment_languages", page.driver.browser.switch_to.active_element.attribute("id")
      assert_equal count, account.firm.assignments.count

      fill_in "assignment_languages", with: "NL, FR"
      click_button I18n.t("marketplace.form.submit", locale:)
      assert_error_summary(locale)
      assert_equal count, account.firm.assignments.count
      assert_field "assignment_title", with: title
      assert_field "assignment_languages", with: "NL, FR"
      assert_field "assignment_fee_cents", with: ""
      assert find("#assignment_kind_legal_task", visible: :all).checked?
      assert find("#assignment_court", visible: :all).disabled?

      set_datetime("assignment_response_deadline_at", 1.day.from_now)
      set_datetime("assignment_execution_deadline", 3.days.from_now)
      click_button I18n.t("marketplace.form.submit", locale:)
      assert_selector "h1", text: title
      record = Assignment.find_by!(title:)
      assert_equal "legal_task", record.kind
      assert_nil record.fee_cents
      assert_equal "NL, FR", record.languages
      assert_nil record.delivery_due_at
      assert_selector ".proposal-panel__price strong", text: I18n.t("marketplace.fee_unspecified", locale:)
      resize_viewport(1280)
      assert_localized_layout(locale)
    end
  end

  test "settings privacy and report validation preserve data and focus localized errors" do
    member = surface_account("form-member")
    owner = surface_account("form-owner")
    assignment = create_assignment_for(owner, title: "Synthetic report subject")

    LOCALES.each do |locale|
      Capybara.reset_sessions!
      sign_in_member(member.user, locale:)
      resize_viewport(390)
      visit settings_path(locale:)
      original_name = member.user.first_name
      fill_in "account[first_name]", with: "   "
      click_button I18n.t("settings.save", locale:), match: :first
      assert_error_summary(locale)
      assert_equal original_name, member.user.reload.first_name
      assert member.user.marketplace_verified?

      visit new_privacy_request_path(locale:)
      choose_searchable_option("privacy_request_kind", value: "access_export")
      fill_in "privacy_request_details", with: "   "
      privacy_count = member.user.privacy_requests.count
      click_button I18n.t("trust.privacy_requests.new.submit", locale:)
      assert_error_summary(locale)
      assert_equal privacy_count, member.user.privacy_requests.count

      visit new_assignment_report_path(assignment, locale:)
      choose_searchable_option("report_category", value: "misleading")
      fill_in "report_details", with: "   "
      report_count = member.user.submitted_reports.count
      click_button I18n.t("trust.reports.new.submit", locale:)
      assert_error_summary(locale)
      assert_equal report_count, member.user.submitted_reports.count
      assert_equal "open", assignment.reload.status
    end
  end

  private

  def surface_account(prefix, **options)
    account = create_marketplace_account(prefix: "surface-#{prefix}", **options)
    (@surface_accounts ||= []) << account
    account
  end

  def sign_in_member(user, locale:)
    visit new_session_path(locale:)
    fill_in "email_address", with: user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    destination = user.marketplace_verified? ? dashboard_path(locale:) : verification_status_path(locale:)
    assert_current_path destination
  end

  def resize_viewport(width)
    if page.driver.browser.respond_to?(:execute_cdp)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 900, deviceScaleFactor: 1, mobile: false)
    else
      page.current_window.resize_to(width, 900)
    end
  end

  def assert_localized_layout(locale)
    assert_selector "html[lang='#{locale}']"
    assert_selector "main", count: 1
    assert_no_text(/translation missing|content missing/i)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth"), "Page overflows in #{locale}"
  end

  def assert_error_summary(locale)
    assert_selector ".form-error[role='alert']:focus"
    assert_includes page.driver.browser.switch_to.active_element.attribute("class"), "form-error"
    assert_localized_layout(locale)
  end

  def set_datetime(id, time)
    page.execute_script(<<~JAVASCRIPT, id, time.strftime("%Y-%m-%dT%H:%M"))
      const input = document.getElementById(arguments[0]);
      input.value = arguments[1];
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    JAVASCRIPT
  end

  def remove_surface_records
    accounts = @surface_accounts || []
    return if accounts.empty?

    user_ids = accounts.map { |account| account.user.id }
    firm_ids = accounts.map { |account| account.firm.id }
    assignment_ids = Assignment.where(firm_id: firm_ids).pluck(:id)
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Report.where(reporter_user_id: user_ids).or(Report.where(reportable_type: "Assignment", reportable_id: assignment_ids)).delete_all
    PrivacyRequest.where(user_id: user_ids).delete_all
    Notification.where(user_id: user_ids).delete_all
    Proposal.where(user_id: user_ids).or(Proposal.where(assignment_id: assignment_ids)).delete_all
    Assignment.where(id: assignment_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
  end
end
