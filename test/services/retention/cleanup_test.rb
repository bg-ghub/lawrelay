require "test_helper"
require_relative "../../support/marketplace_test_factory"

class RetentionCleanupTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  test "dry run only counts terminal notification records" do
    user = users(:one)
    old = Notification.create!(user:, kind: "assignment_expired", created_at: 91.days.ago, updated_at: 91.days.ago)
    pending = Notification.create!(user:, kind: "assignment_expired", email_status: "pending", event_key: "retention-pending", created_at: 91.days.ago, updated_at: 91.days.ago)

    result = Retention::Cleanup.new(now: Time.current, dry_run: true).call

    assert_equal 1, result.notifications
    assert old.persisted?
    assert pending.persisted?
  end

  test "terminal notification cleanup leaves pending delivery untouched" do
    user = users(:one)
    old = Notification.create!(user:, kind: "assignment_expired", created_at: 91.days.ago, updated_at: 91.days.ago)
    pending = Notification.create!(user:, kind: "assignment_expired", email_status: "pending", event_key: "retention-delivery", created_at: 91.days.ago, updated_at: 91.days.ago)

    Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert_not Notification.exists?(old.id)
    assert Notification.exists?(pending.id)
  end

  test "active privacy request holds a member from automatic removal" do
    user = users(:two)
    user.update_columns(email_verified_at: nil, created_at: 31.days.ago, updated_at: 31.days.ago)
    PrivacyRequest.create!(user:, kind: "deletion", status: "pending", details: "Please remove my account")

    assert Retention::Protection.held?(user)
    Retention::Cleanup.new(now: Time.current, dry_run: false).call
    assert User.exists?(user.id)
  end

  test "closed work is retained while its report exists" do
    account = create_marketplace_account(prefix: "retention-owner")
    assignment = create_assignment_for(account, title: "Retained reported work")
    assignment.update_columns(status: "expired", starts_at: 3.years.ago, closed_at: 2.years.ago - 1.day)
    report = Report.create!(reporter_user: users(:two), reportable: assignment, category: "other", details: "Keep for review")
    report.update_columns(status: "resolved", resolved_at: 2.years.ago - 1.day)

    Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert Assignment.exists?(assignment.id)
    assert_not Report.exists?(report.id)
  end

  test "expired hold is removed only after the audit window" do
    hold = RetentionHold.create!(subject: users(:one), actor: mfa_admin, reason: "Completed check", expires_at: 1.day.from_now)
    hold.update_column(:expires_at, 1.year.ago - 1.day)

    result = Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert_equal 1, result.retention_holds
    assert_not RetentionHold.exists?(hold.id)
  end

  test "an assignment hold protects its participant and terminal notification" do
    owner = create_marketplace_account(prefix: "retention-owner")
    participant = create_marketplace_account(prefix: "retention-participant")
    assignment = create_assignment_for(owner, title: "Held historical work")
    assignment.update_columns(status: "expired", starts_at: 3.years.ago, closed_at: 2.years.ago - 1.day)
    proposal = create_proposal_for(assignment, participant)
    notification = Notification.create!(user: participant.user, kind: "assignment_expired", subject: proposal,
      data: { assignment_id: assignment.id }, created_at: 91.days.ago, updated_at: 91.days.ago)
    RetentionHold.create!(subject: assignment, actor: mfa_admin, reason: "Open review", expires_at: 1.day.from_now)

    assert Retention::Protection.held?(participant.user)
    Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert Assignment.exists?(assignment.id)
    assert Notification.exists?(notification.id)
  end

  test "proposal without a user does not break protection checks" do
    owner = create_marketplace_account(prefix: "retention-owner")
    assignment = create_assignment_for(owner, title: "Historical work")
    assignment.update_columns(status: "expired", starts_at: 3.years.ago, closed_at: 2.years.ago - 1.day)
    proposal = assignment.proposals.create!(name: "Former lawyer", email: "former@example.test", rate_cents: 100_00,
      rate_kind: "fixed", message: "Historical offer")

    assert_not Retention::Protection.held?(proposal)
  end

  test "a creator hold propagates to related historical work" do
    owner = create_marketplace_account(prefix: "retention-owner")
    assignment = create_assignment_for(owner, title: "Creator-held work")
    assignment.update_columns(status: "expired", starts_at: 3.years.ago, closed_at: 2.years.ago - 1.day)
    RetentionHold.create!(subject: owner.user, actor: mfa_admin, reason: "Deletion review", expires_at: 1.day.from_now)

    assert Retention::Protection.held?(assignment)
  end

  test "resolved privacy request stays while its user is held" do
    account = create_marketplace_account(prefix: "retention-privacy")
    request = PrivacyRequest.create!(user: account.user, kind: "access_export", status: "completed", details: "Historical request")
    request.update_columns(resolved_at: 2.years.ago - 1.day)
    RetentionHold.create!(subject: account.user, actor: mfa_admin, reason: "Deletion review", expires_at: 1.day.from_now)

    Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert PrivacyRequest.exists?(request.id)
  end

  test "isolated unconfirmed registration and its self-audit are removed after thirty days" do
    account = create_marketplace_account(prefix: "retention-unverified", verified: false, email_verified: false)
    user = account.user
    AuditEvent.create!(actor_user: user, firm: account.firm, auditable: user, action: "registration.created")
    user.update_columns(created_at: 31.days.ago, updated_at: 31.days.ago)
    account.profile.update_columns(created_at: 31.days.ago, updated_at: 31.days.ago)

    result = Retention::Cleanup.new(now: Time.current, dry_run: false).call

    assert_equal 1, result.unverified_users
    assert_not User.exists?(user.id)
    assert_not Firm.exists?(account.firm.id)
  end

  test "an established account awaiting email reconfirmation is not an abandoned signup" do
    account = create_marketplace_account(prefix: "retention-existing")
    account.user.update_columns(email_verified_at: nil, updated_at: 31.days.ago)
    account.profile.update_columns(verified_at: nil, verification_status: "pending", updated_at: 31.days.ago)

    Retention::Cleanup.new(dry_run: false).call

    assert User.exists?(account.user.id)
  end

  private

  def mfa_admin
    @mfa_admin ||= begin
      admin = create_marketplace_account(prefix: "retention-admin", system_role: "admin").user
      admin.update_columns(admin_mfa_secret_ciphertext: "configured", admin_mfa_enabled_at: Time.current)
      admin
    end
  end
end
