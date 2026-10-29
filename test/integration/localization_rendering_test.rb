require "test_helper"
require_relative "../support/marketplace_test_factory"

# This is deliberately a rendered-page smoke matrix rather than a catalogue of
# translation keys.  It exercises the values that only appear when records are
# present (statuses, enum labels, dates, amounts and validation messages).
class LocalizationRenderingTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  LOCALES = %i[nl fr de en].freeze

  setup do
    @member = create_marketplace_account(prefix: "localized-member")
    @candidate = create_marketplace_account(prefix: "localized-candidate")
    @pending = create_marketplace_account(prefix: "localized-pending", verified: false, email_verified: false)
    @admin = create_marketplace_account(prefix: "localized-admin", system_role: "admin").user

    @court_assignment = create_assignment_for(@member, title: "Court hearing", status: "open")
    @court_assignment.update!(response_deadline_at: 1.day.from_now)
    @legal_assignment = create_assignment_for(@member, title: "Legal research", status: "open")
    @legal_assignment.update!(
      kind: "legal_task", assignment_subtype: "advice", languages: "NL, FR",
      scope_indication: "Review the supplied documents", response_deadline_at: 1.day.from_now,
      delivery_due_at: 36.hours.from_now
    )
    @proposal = create_proposal_for(@court_assignment, @candidate, rate_cents: 315_00)
    @candidate_assignment = create_assignment_for(@candidate, title: "Candidate hearing", status: "open")
    @billing_account = @member.firm.create_billing_account!(
      provider: "manual", status: "active", plan_key: "founding_beta",
      billing_email: @member.user.email_address, complimentary_access_until: 3.months.from_now
    )
    @billing_account.invoices.create!(
      number: "LR-LOCALIZED-001", status: "issued", subtotal_cents: 250_00,
      vat_rate_basis_points: 2100, issued_on: Date.current, due_on: 30.days.from_now.to_date,
      peppol_status: "manual_required"
    )
    @report = Report.create!(reporter_user: @candidate.user, reportable: @court_assignment,
      category: "misleading", details: "The visible information needs review.")
    Report.create!(reporter_user: @candidate.user, reportable: @legal_assignment,
      category: "misconduct", status: "in_review", reviewed_by_user: @admin,
      details: "A report already under review.")
    @privacy_request = PrivacyRequest.create!(user: @member.user, kind: "access_export",
      details: "Please provide a copy of my account data.")
    AuditEvent.create!(auditable: @member.user, actor_user: @admin, action: "account.email_changed")
    PrivacyRequest.create!(user: @candidate.user, kind: "deletion", status: "in_review",
      handled_by_user: @admin, details: "Please review this deletion request.")
  end

  test "public, authentication, confirmation, and validation pages render in every locale" do
    LOCALES.each do |locale|
      [ root_path(locale:), privacy_path(locale:), terms_path(locale:),
        cookies_path(locale:), legal_notice_path(locale:), new_session_path(locale:),
        admin_login_path(locale:), new_registration_path(locale:), new_password_path(locale:) ].each { |path| render_page(path, locale:) }

      render_page(edit_password_path(token: @member.user.password_reset_token, locale:), locale:)
      render_page(email_verification_path(token: @pending.user.email_verification_token, locale:), locale:)
      render_page(directory_verification_path(token: directory_token_for(@pending), locale:), locale:)

      post registration_path(locale:), params: { registration: { first_name: "", email_address: "not-an-email" } }
      assert_localized_response(locale, "invalid registration form", status: :unprocessable_content)

      sign_in_as(@member.user)
      post assignments_path(locale:), params: { assignment: { title: "", kind: "court_replacement" } }
      assert_localized_response(locale, "invalid assignment form", status: :unprocessable_content)
      sign_out
    end
  end

  test "verified member pages render populated marketplace, billing, privacy, report, and form states in every locale" do
    sign_in_as(@member.user)
    LOCALES.each do |locale|
      [ root_path(locale:), dashboard_path(locale:), assignments_path(locale:), assignment_path(@court_assignment, locale:),
        assignment_path(@legal_assignment, locale:), new_assignment_path(locale:), settings_path(locale:),
        email_change_path(locale:), privacy_requests_path(locale:), new_privacy_request_path(locale:),
        new_assignment_report_path(@candidate_assignment, locale:) ].each { |path| render_page(path, locale:) }

      post privacy_requests_path(locale:), params: { privacy_request: { kind: "", details: "" } }
      assert_localized_response(locale, "invalid privacy request form", status: :unprocessable_content)

      post assignment_reports_path(@candidate_assignment, locale:), params: { report: { category: "", details: "" } }
      assert_localized_response(locale, "invalid report form", status: :unprocessable_content)
    end
  end

  test "pending verification status renders its directory and email states in every locale" do
    sign_in_as(@pending.user)
    LOCALES.each { |locale| render_page(verification_status_path(locale:), locale:) }
  end

  test "closed assignments and participant notifications render in every locale" do
    sign_in_as(@candidate.user)
    %w[new_proposal proposal_accepted proposal_declined assignment_cancelled assignment_expired].each do |kind|
      @candidate.user.notifications.create!(kind:, subject: @court_assignment)
    end
    @proposal.update!(status: "accepted", accepted_at: Time.current)
    %w[matched completed cancelled expired].each do |status|
      @court_assignment.update!(status:)
      LOCALES.each do |locale|
        render_page(assignment_path(@court_assignment, locale:), locale:)
        render_page(dashboard_path(locale:), locale:)
      end
    end
  end

  test "invoice history also renders when previewing paid mode without taking payment" do
    previous_mode = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = "paid"
    sign_in_as(@member.user)
    LOCALES.each do |locale|
      render_page(billing_path(locale:), locale:)
      assert_includes response.body, "LR-LOCALIZED-001"
    end
  ensure
    previous_mode.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = previous_mode
  end

  test "admin MFA, user management, verification, trust, and founding-access pages render in every locale" do
    sign_in_as(@admin, admin_mfa: true)
    LOCALES.each do |locale|
      [ admin_users_path(locale:), admin_user_path(@member.user, locale:), admin_verifications_path(locale:),
        admin_reports_path(locale:), admin_privacy_requests_path(locale:), admin_founding_accesses_path(locale:) ].each do |path|
        render_page(path, locale:)
        if path == admin_user_path(@member.user, locale:)
          assert_includes response.body, I18n.t("admin.users.audit.actions.account_email_changed", locale:)
        end
      end
    end

    sign_out
    # These screens must also render before an administrator has enrolled MFA.
    unenrolled = create_marketplace_account(prefix: "localized-unenrolled-admin", system_role: "admin").user
    sign_in_as(unenrolled)
    LOCALES.each { |locale| render_page(admin_mfa_setup_path(locale:), locale:) }

    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    sign_out
    sign_in_as(@admin)
    LOCALES.each { |locale| render_page(admin_mfa_challenge_path(locale:), locale:) }
  end

  private

  def render_page(path, locale:)
    get path
    assert_localized_response(locale, path)
  end

  def assert_localized_response(locale, page, status: :success)
    assert_response status, "#{page} did not render"
    assert_select "html[lang='#{locale}']", count: 1
    assert_no_match(/translation missing|i18n\.missing_translation/i, response.body, "#{page} contains a missing translation marker")
  end

  def directory_token_for(account)
    profile = account.profile
    profile.update!(
      directory_profile_id: "directory-#{profile.id}", directory_profile_url: "https://example.test/directory/#{profile.id}",
      directory_name: account.user.full_name, directory_email: "directory-#{profile.id}@example.test",
      directory_checked_at: Time.current
    )
    Directory::ConfirmationToken.generate(profile)
  end
end
