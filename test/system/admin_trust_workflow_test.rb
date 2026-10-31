require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AdminTrustWorkflowTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @previous_admin_id = ENV["LAWRELAY_ADMIN_USER_ID"]
    token = SecureRandom.hex(6)
    @admin = User.create!(first_name: "Trust", last_name: "Operator", email_address: "trust-admin-#{token}@example.test",
      password: "password1234", system_role: "admin", email_verified_at: Time.current, locale: "en")
    ENV["LAWRELAY_ADMIN_USER_ID"] = @admin.id.to_s
    @mfa_secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now)
    @admin.update!(admin_mfa_last_verified_at: 2.minutes.ago)
    @owner = create_marketplace_account(prefix: "trust-owner")
    @reporter = create_marketplace_account(prefix: "trust-reporter")
    @assignment = create_assignment_for(@owner, title: "Synthetic reported assignment #{token}")
    @report = Report.create!(reporter_user: @reporter.user, reportable: @assignment,
      category: "misleading", details: "Synthetic report evidence #{token}")
    @request = PrivacyRequest.create!(user: @reporter.user, kind: "deletion", details: "Synthetic deletion request #{token}")
    @other_request = PrivacyRequest.create!(user: @owner.user, kind: "access_export", details: "Separate private request #{token}")
  end

  teardown do
    Capybara.reset_sessions!
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if page.driver.browser.respond_to?(:execute_cdp)
    page.current_window.resize_to(1400, 1400)
    @previous_admin_id.nil? ? ENV.delete("LAWRELAY_ADMIN_USER_ID") : ENV["LAWRELAY_ADMIN_USER_ID"] = @previous_admin_id
    user_ids = [ @admin&.id, @owner&.user&.id, @reporter&.user&.id ].compact
    firm_ids = [ @owner&.firm&.id, @reporter&.firm&.id ].compact
    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Report.where(reporter_user_id: user_ids).delete_all
    PrivacyRequest.where(user_id: user_ids).delete_all
    Notification.where(user_id: user_ids).delete_all
    Assignment.where(firm_id: firm_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    User.where(id: user_ids).delete_all
    Firm.where(id: firm_ids).delete_all
  end

  test "populated trust queues stay usable in every language and review actions preserve the evidence" do
    sign_in_admin

    %i[nl fr de en].each do |locale|
      [ 320, 1280 ].each do |width|
        resize_viewport(width)
        [ admin_reports_path(locale:), admin_privacy_requests_path(locale:) ].each do |path|
          visit path
          assert_selector "html[lang='#{locale}']"
          assert_no_text "Translation missing"
          assert_equal 1, all("main", visible: :all).size
          assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth"), "Trust queue overflows at #{width}px in #{locale}"
          assert_selector ".trust-review-form textarea", minimum: 1
          all(".trust-review-form textarea").each { |field| assert field.native.accessible_name.present? }
        end
      end

      visit admin_reports_path(locale:)
      unchanged_report = @report.reload.attributes.slice("status", "resolution_note", "resolved_at")
      submit_review(@report, :resolve, locale:, note: "")
      assert_text I18n.t("trust.admin.notices.note_required", locale:)
      assert_equal unchanged_report, @report.reload.attributes.slice("status", "resolution_note", "resolved_at")

      submit_review(@report, :review, locale:)
      assert_reopened(@report)
      submit_review(@report, :resolve, locale:, note: "Synthetic resolution #{locale}")
      assert_equal "resolved", @report.reload.status
      assert_not_nil @report.resolved_at
      assert_equal @admin, @report.reviewed_by_user
      assert @report.audit_events.exists?(action: "report.resolve")
      submit_review(@report, :review, locale:)
      assert_reopened(@report)
      submit_review(@report, :dismiss, locale:, note: "Synthetic dismissal #{locale}")
      assert_equal "dismissed", @report.reload.status
      assert @report.audit_events.exists?(action: "report.dismiss")
      assert_equal @assignment.id, @report.reportable_id
      assert_includes @report.details, "Synthetic report evidence"

      visit admin_privacy_requests_path(locale:)
      assert_text I18n.t("trust.admin.privacy_requests.action_note", locale:)
      unchanged_request = @request.reload.attributes.slice("status", "resolution_note", "resolved_at")
      submit_review(@request, :complete, locale:, note: "")
      assert_text I18n.t("trust.admin.notices.note_required", locale:)
      assert_equal unchanged_request, @request.reload.attributes.slice("status", "resolution_note", "resolved_at")

      submit_review(@request, :review, locale:)
      assert_reopened(@request)
      submit_review(@request, :complete, locale:, note: "Synthetic handling record #{locale}")
      assert_equal "completed", @request.reload.status
      assert_equal @admin, @request.handled_by_user
      assert_not_nil @request.resolved_at
      assert @request.audit_events.exists?(action: "privacy_request.complete")
      assert User.exists?(@reporter.user.id), "Recording a decision must not erase an account"
      assert_nil @reporter.user.reload.erased_at
      assert @reporter.user.marketplace_verified?
      submit_review(@request, :review, locale:)
      assert_reopened(@request)
      submit_review(@request, :reject, locale:, note: "Synthetic rejection record #{locale}")
      assert_equal "rejected", @request.reload.status
      assert @request.audit_events.exists?(action: "privacy_request.reject")
    end
  end

  test "expired administrator MFA protects both populated queues and rejects an invalid code" do
    sign_in_admin

    travel 13.hours do
      visit admin_privacy_requests_path(locale: :en)
      assert_current_path admin_mfa_challenge_path(locale: :en)
      assert_no_text @request.details
      assert_no_selector ".trust-review-form"
      fill_in "mfa_code", with: "invalid"
      click_button I18n.t("mfa.challenge.submit", locale: :en)
      assert_text I18n.t("mfa.notices.invalid_code", locale: :en)
      assert_current_path admin_mfa_challenge_path(locale: :en)
      assert_no_text @request.details
      visit admin_reports_path(locale: :en)
      assert_current_path admin_mfa_challenge_path(locale: :en)
      assert_no_text @report.details

      fill_in "mfa_code", with: ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now
      click_button I18n.t("mfa.challenge.submit", locale: :en)
      assert_current_path admin_reports_path(locale: :en)
      assert_text @report.details
      assert_equal "open", @report.reload.status
      assert_equal "pending", @request.reload.status
    end
  end

  test "members see only their own privacy requests and never the administrator review controls" do
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @reporter.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    resize_viewport(320)

    %i[nl fr de en].each do |locale|
      visit privacy_requests_path(locale:)
      assert_member_privacy_layout(locale:)
      assert_selector ".trust-list .trust-row", count: 1
      assert_text I18n.t("trust.privacy_requests.kinds.deletion", locale:)
      assert_no_text I18n.t("trust.privacy_requests.kinds.access_export", locale:)
      assert_no_text @other_request.details

      click_link I18n.t("trust.privacy_requests.index.new", locale:)
      assert_current_path new_privacy_request_path(locale:)
      assert_member_privacy_layout(locale:)
      assert_selector "input#privacy_request_kind-search[role='combobox']"
      assert_selector "textarea#privacy_request_details"
      all(".assignment-form [role='combobox'], .assignment-form textarea").each do |field|
        assert field.native.accessible_name.present?
      end

      [ admin_reports_path(locale:), admin_privacy_requests_path(locale:) ].each do |path|
        visit path
        assert_current_path root_path(locale:)
        assert_no_selector ".trust-review-form"
        assert_no_text @report.details
        assert_no_text @other_request.details
      end
    end
    assert_equal "open", @report.reload.status
    assert_equal "pending", @request.reload.status
  end

  private

  def sign_in_admin
    visit admin_reports_path(locale: :en)
    assert_current_path admin_login_path(locale: :en)
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path admin_mfa_challenge_path(locale: :en)
    assert_no_text @report.details
    assert_no_selector ".trust-review-form"
    fill_in "mfa_code", with: ROTP::TOTP.new(@mfa_secret, issuer: "LawRelay").now
    click_button I18n.t("mfa.challenge.submit", locale: :en)
    assert_current_path admin_reports_path(locale: :en)
  end

  def submit_review(record, decision, locale:, note: nil)
    path = record.is_a?(Report) ? admin_report_path(record, locale:) : admin_privacy_request_path(record, locale:)
    within("form[action='#{path}']") do
      fill_in I18n.t("trust.admin.resolution_note", locale:), with: note unless note.nil?
      # Native keyboard activation is more reliable than a pointer click here: the
      # rows can be below the viewport after several Turbo updates.
      find("button[name='decision'][value='#{decision}']").send_keys(:enter)
    end
    return if note == ""

    expected_status = { review: "in_review", resolve: "resolved", dismiss: "dismissed", complete: "completed", reject: "rejected" }.fetch(decision)
    within(".trust-row", text: record.details) do
      assert_selector ".status-pill", text: /#{Regexp.escape(I18n.t("trust.statuses.#{expected_status}", locale:))}/i
    end
    assert_text I18n.t("trust.admin.notices.updated", locale:)
  end

  def assert_reopened(record)
    assert_equal "in_review", record.reload.status
    assert_nil record.resolved_at
    assert_nil record.resolution_note
  end

  def assert_member_privacy_layout(locale:)
    assert_selector "html[lang='#{locale}']"
    assert_no_text "Translation missing"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, page.evaluate_script("window.innerWidth"), "Member privacy page overflows at 320px in #{locale}"
    assert page.evaluate_script(<<~JS), "Member privacy controls overflow at 320px in #{locale}"
      Array.from(document.querySelectorAll('.trust-page .button, .trust-page [role="combobox"], .trust-page textarea')).every(element => {
        const rect = element.getBoundingClientRect();
        return rect.left >= 0 && rect.right <= window.innerWidth;
      })
    JS
  end

  def resize_viewport(width)
    page.current_window.resize_to(width, 1000)
    return unless page.driver.browser.respond_to?(:execute_cdp)

    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 1000, deviceScaleFactor: 1, mobile: false)
  end
end
