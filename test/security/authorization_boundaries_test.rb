require "test_helper"
require_relative "../support/marketplace_test_factory"

class AuthorizationBoundariesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @owner = create_marketplace_account(prefix: "security-owner")
    @member = create_marketplace_account(prefix: "security-member")
    @other = create_marketplace_account(prefix: "security-other")
    @assignment = create_assignment_for(@owner)
  end

  test "assignment ownership state and private invoice fields cannot be injected on creation" do
    sign_in_as(@member.user)

    assert_difference "Assignment.count", 1 do
      post assignments_path(locale: :en), params: { assignment: {
        kind: "court_replacement", title: "Authorized member assignment", description: "A synthetic security test.",
        city: "Brussels", court: "Enterprise Court", practice_area: "Commercial law",
        starts_at: 2.days.from_now, response_deadline_at: 1.day.from_now, duration_minutes: 60,
        fee_cents: "250", content_rules_accepted: "1", firm_id: @owner.firm.id,
        creator_user_id: @owner.user.id, status: "matched", urgent: true,
        invoice_name: "Injected private recipient", invoice_email: @owner.user.email_address,
        content_rules_accepted_at: nil
      } }
    end

    assignment = Assignment.order(:id).last
    assert_redirected_to assignment_path(assignment, locale: :en)
    assert_equal @member.firm.id, assignment.firm_id
    assert_equal @member.user.id, assignment.creator_user_id
    assert_equal "open", assignment.status
    assert_not assignment.urgent
    assert_nil assignment.invoice_name
    assert_nil assignment.invoice_email
    assert_not_nil assignment.content_rules_accepted_at
  end

  test "proposal ownership assignment and acceptance fields cannot be injected" do
    other_assignment = create_assignment_for(@other)
    sign_in_as(@member.user)

    assert_difference "Proposal.count", 1 do
      post assignment_proposals_path(@assignment, locale: :en), params: { proposal: {
        rate_cents: "125", rate_kind: "fixed", message: "A synthetic offer.",
        user_id: @other.user.id, firm_id: @other.firm.id, assignment_id: other_assignment.id,
        name: @other.user.full_name, email: @other.user.email_address,
        status: "accepted", accepted_at: Time.current, declined_at: Time.current
      } }
    end

    proposal = Proposal.order(:id).last
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal @assignment.id, proposal.assignment_id
    assert_equal @member.user.id, proposal.user_id
    assert_equal @member.firm.id, proposal.firm_id
    assert_equal @member.user.full_name, proposal.name
    assert_equal @member.user.email_address, proposal.email
    assert_equal "pending", proposal.status
    assert_nil proposal.accepted_at
    assert_nil proposal.declined_at
    assert_equal "open", @assignment.reload.status
  end

  test "report identity polymorphic target and resolution fields cannot be injected" do
    sign_in_as(@member.user)

    assert_difference "Report.count", 1 do
      post assignment_reports_path(@assignment, locale: :en), params: { report: {
        category: "other", details: "A synthetic report.", reporter_user_id: @other.user.id,
        reportable_type: "User", reportable_id: @other.user.id, status: "resolved",
        reviewed_by_user_id: @other.user.id, resolution_note: "Injected review", resolved_at: Time.current
      } }
    end

    report = Report.order(:id).last
    assert_redirected_to assignment_path(@assignment, locale: :en)
    assert_equal @member.user.id, report.reporter_user_id
    assert_equal @assignment, report.reportable
    assert_equal "open", report.status
    assert_nil report.reviewed_by_user_id
    assert_nil report.resolution_note
    assert_nil report.resolved_at
  end

  test "notification updates cannot reassign ownership subject or redirect metadata" do
    notification = @member.user.notifications.create!(kind: "assignment_completed", subject: @assignment,
      data: { assignment_id: @assignment.id })
    sign_in_as(@member.user)

    patch notification_path(notification, locale: :en), params: { notification: {
      user_id: @other.user.id, subject_type: "User", subject_id: @other.user.id,
      data: { assignment_id: "https://outside.example" }, read_at: nil
    } }

    assert_redirected_to dashboard_path(locale: :en)
    notification.reload
    assert_equal @member.user.id, notification.user_id
    assert_equal @assignment, notification.subject
    assert_equal({ "assignment_id" => @assignment.id }, notification.data)
    assert_not_nil notification.read_at
  end

  test "loss of professional verification blocks direct notification mutations" do
    notification = @member.user.notifications.create!(kind: "assignment_completed", subject: @assignment)
    sign_in_as(@member.user)
    @member.profile.update!(verification_status: "pending", verified_at: nil)

    patch notification_path(notification, locale: :en)
    assert_redirected_to verification_status_path(locale: :en)
    patch mark_all_notifications_path(locale: :en), params: { from: "notifications", user_id: @other.user.id }
    assert_redirected_to verification_status_path(locale: :en)
    assert_nil notification.reload.read_at
  end

  test "role and fresh MFA gates precede every representative administrative mutation" do
    administrator = create_marketplace_account(prefix: "security-administrator", system_role: "admin")
    privacy_request = @other.user.privacy_requests.create!(kind: "correction", details: "Synthetic private request.")
    report = @member.user.submitted_reports.create!(reportable: @assignment, category: "other", details: "Synthetic report.")
    targets = [
      [ suspend_admin_user_path(@other.user, locale: :en), { user_management: { reason: "Forged suspension" } } ],
      [ admin_verification_path(@other.user, locale: :en), { decision: "reject" } ],
      [ admin_report_path(report, locale: :en), { decision: "dismiss", report: { resolution_note: "Forged resolution" } } ],
      [ admin_privacy_request_path(privacy_request, locale: :en), { decision: "reject", privacy_request: { resolution_note: "Forged rejection" } } ]
    ]

    [ @member.user, administrator.user ].each do |actor|
      sign_in_as(actor)
      targets.each do |path, payload|
        assert_no_difference [ "AuditEvent.count", "Notification.count" ] do
          patch path, params: payload.merge(system_role: "admin", admin_mfa_verified: true)
        end
        assert_redirected_to(actor.system_admin? ? admin_mfa_setup_path(locale: :en) : root_path(locale: :en))
      end
    end

    assert_not @other.user.reload.suspended?
    assert_equal "verified", @other.profile.reload.verification_status
    assert_equal "open", report.reload.status
    assert_equal "pending", privacy_request.reload.status
  end
end
