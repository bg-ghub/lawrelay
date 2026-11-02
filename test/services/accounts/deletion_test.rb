require "test_helper"
require_relative "../../support/marketplace_test_factory"

class AccountsDeletionTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []
  self.use_transactional_tests = false

  def before_setup
    clear_disposable_database
    super
  end

  def after_teardown
    super
  ensure
    clear_disposable_database
  end

  setup do
    @account = create_marketplace_account(prefix: "grace-domain")
    @user = @account.user
    @session = @user.sessions.create!
    @ledger = Struct.new(:records) do
      def stage!(user, erased_at:)
        records << { "user_id" => user.id, "user_created_at" => user.created_at.utc.iso8601(6), "erased_at" => erased_at.utc.iso8601(6) }
        "synthetic-operation"
      end
      def commit!(_operation) = true
      def abort!(_operation) = records.clear
      def reconcile! = true
      def entries = records
    end.new([])
  end

  test "scheduling disables immediately but preserves data and records a 30 day deadline" do
    email = @user.email_address
    extra_session = @user.sessions.create!
    request = schedule

    assert @user.reload.deletion_pending?
    assert @user.deletion_recoverable?
    assert_not @user.active?
    assert_not @user.marketplace_verified?
    assert_nil @user.erased_at
    assert_equal email, @user.email_address
    assert @user.lawyer_profile
    assert_equal request.requested_at + 30.days, request.scheduled_at
    assert_equal request.id, @user.deletion_request_id
    assert_not Session.exists?(extra_session.id)
    assert_empty @user.sessions
    assert_empty @ledger.records
    assert_equal 0, PrivacyRequest.count
    assert_equal "pending", request.requested_email_status
    assert AuditEvent.exists?(auditable: request, action: "account.deletion_requested")
    assert_enqueued_with(job: AccountDeletionNoticeJob, args: [ request.id, "requested" ])
    assert_enqueued_with(job: FinalizeAccountDeletionJob, args: [ request.id ])
  end

  test "repeated scheduling with a fresh recovery session preserves its original cycle and deadline" do
    first = schedule
    replacement_session = @user.sessions.create!
    assert_no_difference "AccountDeletionRequest.count" do
      second = Accounts::Deletion.schedule!(user: @user, current_session: replacement_session, password: "password1234")
      assert_equal first.id, second.id
      assert_equal first.scheduled_at, second.scheduled_at
    end
  end

  test "cancellation restores eligibility without changing professional evidence and makes old jobs inert" do
    evidence = @account.profile.attributes
    request = schedule
    recovery_session = @user.sessions.create!
    cancelled = Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234")

    assert_equal request.id, cancelled.id
    assert @user.reload.active?
    assert @user.marketplace_verified?
    assert_not @user.deletion_pending?
    assert_nil @user.deletion_request_id
    assert_empty @user.sessions
    assert_equal evidence, @account.profile.reload.attributes
    assert_equal "cancelled", cancelled.finalization_status
    assert cancelled.cancelled_at
    assert_equal "pending", cancelled.cancelled_email_status
    assert_equal "skipped", cancelled.requested_email_status
    travel_to request.scheduled_at + 1.minute do
      FinalizeAccountDeletionJob.perform_now(request.id)
      assert @user.reload.active?
      assert_nil @user.erased_at
    end
    assert_empty @ledger.records
  end

  test "due finalization uses the existing ledger and clears recovery markers" do
    request = schedule
    travel_to request.scheduled_at + 1.second do
      assert request.claim_finalization!
      assert Accounts::Deletion.finalize!(request:, ledger: @ledger)
    end
    assert @user.reload.erased_at
    assert_nil @user.deletion_requested_at
    assert_nil @user.deletion_scheduled_at
    assert_nil @user.deletion_request_id
    assert_not @user.deletion_recoverable?
    assert_not @user.active?
    assert_nil @user.lawyer_profile
    assert_equal [ @user.id ], @ledger.records.pluck("user_id")
    assert request.reload.completed_at
    assert_equal "completed", request.finalization_status
    assert_nil request.email_identity_digest
    assert_equal "completed", request.privacy_request.status
  end

  test "an early or cancelled finalization cannot erase the user" do
    request = schedule
    assert_not request.claim_finalization!
    assert_not Accounts::Deletion.finalize!(request:, ledger: @ledger)
    assert_empty @ledger.records
    assert_nil @user.reload.erased_at
  end

  test "a new hold arising during the grace period still prevents irreversible erasure" do
    request = schedule
    admin = create_marketplace_account(prefix: "grace-hold-admin", system_role: "admin").user
    admin.update!(admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    RetentionHold.create!(subject: @user, actor: admin, reason: "Synthetic legal hold", expires_at: 60.days.from_now)
    travel_to request.scheduled_at + 1.second do
      assert request.claim_finalization!
      assert_raises(Privacy::AccountErasure::ProtectedAccount) { Accounts::Deletion.finalize!(request:, ledger: @ledger) }
    end
    assert_nil @user.reload.erased_at
    assert @user.deletion_pending?
    assert_empty @ledger.records
  end

  test "open work blocks scheduling without changing data or revoking sessions" do
    create_assignment_for(@account)
    assert_no_difference "AccountDeletionRequest.count" do
      assert_raises(Privacy::AccountErasure::ProtectedAccount) { schedule }
    end
    assert @user.reload.active?
    assert Session.exists?(@session.id)
  end

  test "wrong or revoked credentials cannot schedule or cancel deletion" do
    assert_raises(Accounts::Deletion::InvalidPassword) do
      Accounts::Deletion.schedule!(user: @user, current_session: @session, password: "wrong")
    end
    @session.destroy!
    assert_raises(Accounts::Deletion::InvalidSession) { schedule }
    assert_not @user.reload.deletion_pending?

    @session = @user.sessions.create!
    request = schedule
    session = @user.sessions.create!
    @user.update!(password: "a-new-test-password")
    assert_raises(Accounts::Deletion::InvalidPassword) do
      Accounts::Deletion.cancel!(user: @user, current_session: session, password: "password1234")
    end
    assert request.reload.current_cycle?(@user.reload)
  end

  test "MFA-enabled accounts require a verified current session under the user lock" do
    @user.update!(two_factor_enabled_at: 1.hour.ago, two_factor_secret_ciphertext: "synthetic-secret")
    assert_raises(Accounts::Deletion::InvalidSession) { schedule }
    @session.mark_two_factor_verified!
    request = schedule
    recovery_session = @user.sessions.create!
    assert_raises(Accounts::Deletion::InvalidSession) do
      Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234")
    end
    recovery_session.mark_two_factor_verified!
    assert_equal request.id, Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234").id
  end

  test "suspended and administrator accounts cannot acquire recovery access" do
    @user.update!(suspended_at: Time.current)
    assert_raises(Accounts::Deletion::Unavailable) { schedule }
    @user.update!(suspended_at: nil, system_role: "admin")
    assert_raises(Accounts::Deletion::Unavailable) { schedule }
    assert_not @user.deletion_recoverable?
  end

  test "a restored pending cycle is paused so a later lost cancellation cannot cause erasure" do
    request = schedule
    assert_equal 1, Accounts::Deletion.pause_after_restore!
    assert request.reload.paused?
    assert @user.reload.deletion_pending?
    assert_not @user.active?
    assert_equal "skipped", request.requested_email_status
    assert_not AccountDeletionRequest.unhealthy?
    travel_to request.scheduled_at + 1.day do
      assert_not request.claim_finalization!
      assert_not Accounts::Deletion.finalize!(request:, ledger: @ledger)
    end
    recovery_session = @user.sessions.create!
    Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234")
    assert @user.reload.active?
    assert_empty @ledger.records
  end

  test "suspension during grace never erases or reactivates the member and raises an operations finding" do
    request = schedule
    request.update!(requested_email_status: "sent", requested_email_sent_at: Time.current)
    @user.update!(suspended_at: Time.current)
    travel_to request.scheduled_at + 1.second do
      assert_not AccountDeletionRequest.unhealthy?
      FinalizeAccountDeletionJob.perform_now(request.id)
      assert request.reload.paused?
      assert_equal "review_required", request.finalization_reason
      assert AccountDeletionRequest.unhealthy?
    end
    assert_nil @user.reload.erased_at
    assert_not @user.active?
    assert_not @user.deletion_recoverable?
  end

  test "owner cancellation also prevents an administrator erasing the linked scheduled request" do
    request = schedule
    admin = create_marketplace_account(prefix: "grace-review-admin", system_role: "admin").user
    admin.update!(admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    privacy_request = @user.privacy_requests.create!(kind: "deletion", status: "in_review", handled_by_user: admin,
      details: "Synthetic scheduled deletion review.", resolution_note: "Existing reviewer context")
    request.update!(privacy_request:)
    recovery_session = @user.sessions.create!
    Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234")
    assert_equal "rejected", privacy_request.reload.status
    assert_equal admin.id, privacy_request.handled_by_user_id
    assert_equal "Existing reviewer context", privacy_request.resolution_note
    assert privacy_request.audit_events.exists?(action: "privacy_request.withdrawn")
    privacy_request.update!(status: "in_review", resolved_at: nil)
    assert_raises(Privacy::RequestContext::InvalidRequest) do
      Privacy::AccountErasure.new(request: privacy_request, actor: admin, ledger: @ledger).call
    end
    assert @user.reload.active?
    assert_empty @ledger.records
    Accounts::Deletion.reconcile_cancelled_privacy_requests
    assert_equal "rejected", privacy_request.reload.status
    fresh_request = @user.privacy_requests.create!(kind: "deletion", status: "in_review", handled_by_user: admin,
      details: "Independent request for immediate erasure.")
    assert Privacy::AccountErasure.new(request: fresh_request, actor: admin, ledger: @ledger).call
    assert @user.reload.erased_at
  end

  test "pending members cannot create marketplace work through model-level calls" do
    schedule
    assert_raises(ActiveRecord::RecordInvalid) { create_assignment_for(@account) }
    other = create_marketplace_account(prefix: "grace-model-peer")
    assignment = create_assignment_for(other)
    assert_raises(ActiveRecord::RecordInvalid) { create_proposal_for(assignment, @account) }
    assert_not @user.reload.marketplace_verified?
  end

  test "final-erasure ledger replay clears restored pending fields as well" do
    request = schedule
    backup = @user.attributes
    travel_to request.scheduled_at + 1.second do
      request.claim_finalization!
      Accounts::Deletion.finalize!(request:, ledger: @ledger)
      @user.update_columns(backup.except("id", "public_id"))
      request.update_columns(completed_at: nil, finalization_status: "pending")
      assert_equal 1, Privacy::AccountErasure.reapply!(ledger: @ledger)
    end
    assert @user.reload.erased_at
    assert_nil @user.deletion_request_id
    assert_not @user.deletion_pending?
    assert_equal "completed", request.reload.finalization_status
  end

  private

  def schedule
    Accounts::Deletion.schedule!(user: @user, current_session: @session, password: "password1234")
  end

  def clear_disposable_database
    connection = ActiveRecord::Base.connection
    return unless connection.table_exists?(:users)

    connection.disable_referential_integrity do
      (connection.tables - %w[schema_migrations ar_internal_metadata]).each do |table|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
      end
    end
  end
end
