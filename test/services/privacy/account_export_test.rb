require "test_helper"
require "tmpdir"
require "json"
require_relative "../../support/marketplace_test_factory"

class PrivacyAccountExportTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup do
    @member = create_marketplace_account(prefix: "exportmember")
    @other = create_marketplace_account(prefix: "exportother")
    @admin = User.create!(first_name: "Export", last_name: "Operator", email_address: "export-admin@example.test",
      password: "safe-password-123", system_role: "admin", email_verified_at: Time.current,
      admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "excluded-admin-secret")
    @request = @member.user.privacy_requests.create!(kind: "access_export", status: "in_review",
      handled_by_user: @admin, details: "Please export my account.", resolution_note: "private-operator-note")
    @directory = Dir.mktmpdir("lawrelay-privacy-test-")
    File.chmod(0o700, @directory)
    @output = File.join(@directory, "review.json")
  end

  teardown do
    FileUtils.remove_entry_secure(@directory) if @directory && File.directory?(@directory)
  end

  test "package is allowlisted and scoped to authored records, never secrets or counterpart details" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    own_assignment = create_assignment_for(@member)
    own_assignment.update_columns(invoice_name: "Own invoice firm", invoice_enterprise_number: "BE0123456789",
      invoice_email: "own-invoice@example.test", invoice_address_line_1: "Own street 1", invoice_postal_code: "9000", invoice_city: "Gent",
      invoice_kbo_details: { "snapshot_date" => "2026-10-15", "fields" => [ "name", "enterprise_number" ] })
    other_assignment = create_assignment_for(@other, title: "excluded-other-assignment")
    other_assignment.update_columns(invoice_name: "Other invoice firm", invoice_email: "other-invoice@example.test")
    create_proposal_for(own_assignment, @other, message: "excluded-counterpart-message")
    own_proposal = create_proposal_for(other_assignment, @member, message: "My own proposal")
    @member.user.update!(two_factor_secret_ciphertext: "excluded-two-factor-secret", two_factor_recovery_code_digests: [ "excluded-recovery-digest" ])
    @member.profile.update!(verification_note: "excluded-private-verification-note", directory_identity_digest: "excluded-directory-digest")
    @member.profile.update_columns(email_review_status: "approved", email_review_email_address: @member.user.email_address,
      email_review_requested_at: 2.hours.ago, email_reviewed_at: 1.hour.ago, email_reviewed_by_user_id: @admin.id,
      email_review_note: "excluded-private-email-review-note", email_review_identity_digest: "excluded-email-review-digest")
    @member.user.memberships.create!(firm: @other.firm)
    @other.firm.update!(billing_email: "excluded-billing@example.test")
    @member.user.notifications.create!(kind: "new_proposal", data: { unsafe: "excluded-notification-data" })
    @other.user.notifications.create!(kind: "new_proposal", data: {})
    @member.user.sessions.create!(ip_address: "192.0.2.10", user_agent: "Test browser", expires_at: 1.day.from_now)
    AuditEvent.create!(auditable: @member.user, actor_user: @admin, action: "user.updated", metadata: { note: "excluded-audit-metadata" })
    @other.user.privacy_requests.create!(kind: "correction", details: "excluded-other-request")

    assert_difference("AuditEvent.where(action: 'privacy.export_prepared').count", 1) do
      assert_no_difference([ "User.count", "Assignment.count", "Proposal.count", "PrivacyRequest.count", "Session.count" ]) do
        Privacy::AccountExport.new(request: @request, actor: @admin).call(output_path: @output)
      end
    end

    raw = File.read(@output)
    package = JSON.parse(raw)
    assert_equal @member.user.email_address, package.dig("account", "email_address")
    assert_equal @member.user.public_id, package.dig("account", "public_id")
    exported_profile = package.fetch("professional_profile")
    assert_equal "approved", exported_profile.fetch("email_review_status")
    assert_equal @member.user.email_address, exported_profile.fetch("email_review_email_address")
    assert exported_profile.fetch("email_review_requested_at")
    assert exported_profile.fetch("email_reviewed_at")
    %w[email_review_note email_review_identity_digest email_reviewed_by_user_id].each do |field|
      assert_not exported_profile.key?(field)
    end
    assert_equal [ own_assignment.id ], package.fetch("authored_assignments").pluck("id")
    exported_assignment = package.fetch("authored_assignments").sole
    assert_equal "Own invoice firm", exported_assignment.fetch("invoice_name")
    assert_equal "own-invoice@example.test", exported_assignment.fetch("invoice_email")
    assert_equal({ "snapshot_date" => "2026-10-15", "fields" => [ "name", "enterprise_number" ] }, exported_assignment.fetch("invoice_kbo_details"))
    assert_equal [ own_proposal.id ], package.fetch("authored_proposals").pluck("id")
    assert_equal @member.user.notifications.order(:id).pluck(:id), package.fetch("notifications").pluck("id")
    assert_equal "192.0.2.10", package.fetch("sessions").sole.fetch("ip_address")
    assert_equal @request.id, package.fetch("privacy_requests").sole.fetch("id")
    assert_equal true, package.fetch("review_required")
    assert_equal "in_review", @request.reload.status
    assert_nil @request.resolved_at
    refute_includes raw, "excluded-"
    refute_includes raw, "Other invoice firm"
    refute_includes raw, "other-invoice@example.test"
    refute_includes raw, @member.user.password_digest
    refute_includes raw, @other.user.email_address
    refute_includes raw, "password_digest"
    refute_includes raw, "recovery_code"
    assert_equal 0o600, File.stat(@output).mode & 0o777
    event = AuditEvent.where(action: "privacy.export_prepared").sole
    assert_equal @admin, event.actor_user
    assert_equal @request, event.auditable
    assert_equal({ "source" => "rake", "format_version" => 1 }, event.metadata)
  end

  test "wrong kind, unassigned and closed requests are refused before any output" do
    [ { kind: "deletion" }, { status: "completed" }, { handled_by_user_id: nil } ].each do |changes|
      original = @request.attributes.slice(*changes.keys.map(&:to_s))
      @request.update!(changes)
      assert_rejected
      @request.update!(original)
    end
  end

  test "member, suspended and MFA-unconfigured operators are refused" do
    assert_rejected(actor: @member.user)
    @admin.update!(suspended_at: Time.current)
    assert_rejected
    @admin.update!(suspended_at: nil, admin_mfa_enabled_at: nil)
    assert_rejected
  end

  test "a stale operator cannot keep exporting after role changes" do
    stale_actor = User.find(@admin.id)
    @admin.update!(system_role: "member")
    assert_rejected(actor: stale_actor)
  end

  test "administrator identities cannot use the member export helper" do
    @member.user.update!(system_role: "admin")
    assert_rejected
  end

  test "audit failure removes the newly created package" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    original_create = AuditEvent.method(:create!)
    AuditEvent.define_singleton_method(:create!) { |*| raise ActiveRecord::RecordInvalid }
    assert_raises(ActiveRecord::RecordInvalid) do
      Privacy::AccountExport.new(request: @request, actor: @admin).call(output_path: @output)
    end
    refute File.exist?(@output)
    assert_equal "in_review", @request.reload.status
  ensure
    AuditEvent.define_singleton_method(:create!, original_create) if original_create
  end

  private

  def assert_rejected(actor: @admin)
    assert_no_difference("AuditEvent.count") do
      assert_raises(Privacy::RequestContext::InvalidRequest) do
        Privacy::AccountExport.new(request: @request, actor:).call(output_path: @output)
      end
    end
    refute File.exist?(@output)
  end
end
