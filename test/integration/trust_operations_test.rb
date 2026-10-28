require "test_helper"
require_relative "../support/marketplace_test_factory"

class TrustOperationsTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  test "user creates and sees only their own privacy requests" do
    account = create_marketplace_account(prefix: "privacyowner")
    other = create_marketplace_account(prefix: "privacyother")
    other.user.privacy_requests.create!(kind: "correction", details: "Other private request")
    sign_in_as(account.user)

    assert_difference([ "PrivacyRequest.count", "AuditEvent.count" ], 1) do
      post privacy_requests_path(locale: :en), params: {
        privacy_request: { kind: "access_export", details: "Please provide a copy of my account data." }
      }
    end

    assert_redirected_to privacy_requests_path(locale: :en)
    get privacy_requests_path(locale: :en)
    assert_response :success
    assert_includes response.body, "Access or export my data"
    assert_not_includes response.body, "Other private request"
  end

  test "verified lawyer can report a visible assignment but not their own" do
    owner = create_marketplace_account(prefix: "reportowner")
    reporter = create_marketplace_account(prefix: "reporter")
    assignment = create_assignment_for(owner)
    sign_in_as(reporter.user)

    assert_difference([ "Report.count", "AuditEvent.count" ], 1) do
      post assignment_reports_path(assignment, locale: :en), params: {
        report: { category: "confidentiality", details: "The public description appears to identify a client." }
      }
    end
    assert_redirected_to assignment_path(assignment, locale: :en)

    sign_in_as(owner.user)
    assert_no_difference("Report.count") do
      post assignment_reports_path(assignment, locale: :en), params: {
        report: { category: "other", details: "Own assignment report." }
      }
    end
    assert_redirected_to assignment_path(assignment, locale: :en)
  end

  test "system administrator closes trust records with audited notes" do
    requester = create_marketplace_account(prefix: "trustrequester")
    reporter = create_marketplace_account(prefix: "trustreporter")
    owner = create_marketplace_account(prefix: "trustowner")
    admin = create_marketplace_account(prefix: "trustadmin", system_role: "admin")
    privacy_request = requester.user.privacy_requests.create!(kind: "deletion", details: "Close my account.")
    report = reporter.user.submitted_reports.create!(
      reportable: create_assignment_for(owner), category: "misleading", details: "The listing is inaccurate."
    )
    configure_admin_mfa(admin.user)
    sign_in_as(admin.user, admin_mfa: true)

    assert_difference("AuditEvent.count", 2) do
      patch admin_privacy_request_path(privacy_request, locale: :en), params: {
        decision: "complete", privacy_request: { resolution_note: "Identity checked; export retained with the case log." }
      }
      patch admin_report_path(report, locale: :en), params: {
        decision: "resolve", report: { resolution_note: "Posting reviewed and owner contacted." }
      }
    end

    assert_equal "completed", privacy_request.reload.status
    assert_equal admin.user, privacy_request.handled_by_user
    assert_equal "resolved", report.reload.status
    assert_equal admin.user, report.reviewed_by_user
  end

  test "ordinary users cannot enter trust administration" do
    account = create_marketplace_account(prefix: "nonadmintrust")
    sign_in_as(account.user)

    get admin_reports_path(locale: :en)

    assert_redirected_to root_path(locale: :en)
  end

  private

  def configure_admin_mfa(user)
    secret = user.begin_admin_mfa_setup!
    user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
  end
end
