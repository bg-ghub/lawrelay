require "test_helper"
require_relative "../support/marketplace_test_factory"

class AdminTrustReopenTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @owner = create_marketplace_account(prefix: "reopenowner")
    @requester = create_marketplace_account(prefix: "reopenrequester")
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @previous_reviewer = users(:two)
    sign_in_as(@admin, admin_mfa: true)
  end

  test "reopening either closed report clears closure metadata and records only a review" do
    %w[resolved dismissed].each do |status|
      report = closed_report(status)
      closure_event = report.audit_events.create!(
        actor_user: @previous_reviewer,
        action: "report.#{status == 'resolved' ? 'resolve' : 'dismiss'}",
        metadata: { note: report.resolution_note }
      )

      assert_difference(-> { report.audit_events.count }, 1) do
        patch admin_report_path(report, locale: :en), params: { decision: "review" }
      end

      assert_redirected_to admin_reports_path(locale: :en)
      assert_reopened(report, :reviewed_by_user)
      event = report.audit_events.order(:id).last
      assert_equal "report.review", event.action
      assert_equal @admin, event.actor_user
      assert_empty event.metadata
      assert_equal "Original report closure", closure_event.reload.metadata["note"]
    end
  end

  test "reopening either closed privacy request clears closure metadata and records only a review" do
    %w[completed rejected].each do |status|
      request_record = closed_privacy_request(status)
      closure_event = request_record.audit_events.create!(
        actor_user: @previous_reviewer,
        action: "privacy_request.#{status == 'completed' ? 'complete' : 'reject'}",
        metadata: { note: request_record.resolution_note }
      )

      assert_difference(-> { request_record.audit_events.count }, 1) do
        patch admin_privacy_request_path(request_record, locale: :en), params: { decision: "review" }
      end

      assert_redirected_to admin_privacy_requests_path(locale: :en)
      assert_reopened(request_record, :handled_by_user)
      event = request_record.audit_events.order(:id).last
      assert_equal "privacy_request.review", event.action
      assert_equal @admin, event.actor_user
      assert_empty event.metadata
      assert_equal "Original privacy closure", closure_event.reload.metadata["note"]
    end
  end

  test "a failed audit leaves a closed report unchanged" do
    report = closed_report("resolved")
    assert_audit_failure_rolls_back(report, :reviewed_by_user) do
      patch admin_report_path(report, locale: :en), params: { decision: "review" }
    end
  end

  test "a failed audit leaves a closed privacy request unchanged" do
    request_record = closed_privacy_request("completed")
    assert_audit_failure_rolls_back(request_record, :handled_by_user) do
      patch admin_privacy_request_path(request_record, locale: :en), params: { decision: "review" }
    end
  end

  private

  def closed_report(status)
    report = @requester.user.submitted_reports.create!(
      reportable: create_assignment_for(@owner), category: "misleading", details: "Review this listing."
    )
    report.close!(status: status, reviewer: @previous_reviewer, note: "Original report closure")
    report
  end

  def closed_privacy_request(status)
    request_record = @requester.user.privacy_requests.create!(kind: "correction", details: "Correct my account.")
    request_record.close!(status: status, reviewer: @previous_reviewer, note: "Original privacy closure")
    request_record
  end

  def assert_reopened(record, reviewer_association)
    record.reload
    assert_equal "in_review", record.status
    assert_equal @admin, record.public_send(reviewer_association)
    assert_nil record.resolved_at
    assert_nil record.resolution_note
  end

  def assert_audit_failure_rolls_back(record, reviewer_association)
    original = record.attributes.slice("status", "resolved_at", "resolution_note")
    callback = -> { raise "Synthetic audit failure" }
    AuditEvent.set_callback(:create, :before, callback)
    assert_no_difference(-> { record.audit_events.count }) do
      error = assert_raises(RuntimeError) { yield }
      assert_equal "Synthetic audit failure", error.message
    end
    assert_equal original, record.reload.attributes.slice("status", "resolved_at", "resolution_note")
    assert_equal @previous_reviewer, record.public_send(reviewer_association)
  ensure
    AuditEvent.skip_callback(:create, :before, callback) if callback
  end
end
