require "test_helper"
require_relative "../support/marketplace_test_factory"

class AccountDeletionRequestTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper
  self.fixture_table_names = []

  setup do
    @account = create_marketplace_account(prefix: "deletion-outbox")
    @user = @account.user
    @request = Accounts::Deletion.schedule!(user: @user, current_session: @user.sessions.create!, password: "password1234")
  end

  test "notice claims are leased and an expired claimant cannot finish a newer attempt" do
    assert @request.claim_notice!("requested")
    stale = AccountDeletionRequest.find(@request.id)
    assert_not @request.claim_notice!("requested")
    travel 11.minutes do
      assert @request.claim_notice!("requested")
      assert_equal 0, stale.finish_notice!("requested", status: "sent")
      assert_equal "sending", @request.reload.requested_email_status
      assert @request.notice_claim_current?("requested")
      @request.finish_notice!("requested", status: "sent")
      assert_equal "sent", @request.reload.requested_email_status
    end
  end

  test "notice failures persist bounded retries with a value-free reason" do
    assert @request.claim_notice!("requested")
    @request.fail_notice!("requested", error: IOError.new("private mailbox and server information"))
    @request.reload
    assert_equal "pending", @request.requested_email_status
    assert_equal "IOError", @request.requested_email_reason
    assert @request.requested_email_retry_at > Time.current
    assert_not @request.claim_notice!("requested")
    @request.update!(requested_email_attempts: 4, requested_email_retry_at: nil)
    assert @request.claim_notice!("requested")
    @request.fail_notice!("requested", error: IOError.new("private detail"))
    assert_equal "failed", @request.reload.requested_email_status
    assert AccountDeletionRequest.unhealthy?
    assert_not_includes @request.attributes.to_json, "private detail"
  end

  test "reconciliation repairs missing queue submissions without making repeated jobs or new deadlines" do
    deadline = @request.scheduled_at
    clear_enqueued_jobs
    ReconcileAccountDeletionsJob.perform_now
    assert_enqueued_jobs 0
    @request.update!(requested_email_enqueued_at: nil, finalization_enqueued_for: nil)
    assert_enqueued_jobs 2 do
      ReconcileAccountDeletionsJob.perform_now
      ReconcileAccountDeletionsJob.perform_now
    end
    assert_equal deadline, @request.reload.scheduled_at
    payloads = enqueued_jobs.map { |job| job.slice("job_class", "arguments", "locale", "timezone") }.to_json
    assert_not_includes payloads, @user.email_address
    assert_not_includes payloads, @user.first_name
  end

  test "notice identity is bound to its current professional address and lifecycle" do
    assert @request.notice_eligible?("requested", user: @user.reload)
    @user.update!(email_address: "replacement@example.test")
    assert_not @request.notice_eligible?("requested", user: @user)
    @user.update!(email_address: @account.profile.professional_email)
    recovery_session = @user.sessions.create!
    Accounts::Deletion.cancel!(user: @user, current_session: recovery_session, password: "password1234")
    assert_not @request.reload.notice_eligible?("requested", user: @user.reload)
    assert @request.notice_eligible?("cancelled", user: @user)
    Accounts::Deletion.schedule!(user: @user, current_session: @user.sessions.create!, password: "password1234")
    assert_not @request.notice_eligible?("cancelled", user: @user.reload)
  end

  test "finalization failures are bounded and expired queue leases are repairable" do
    travel_to @request.scheduled_at + 1.second do
      assert @request.claim_finalization!
      @request.fail_finalization!(error: Privacy::AccountErasure::ProtectedAccount.new("private hold detail"))
      assert_equal "pending", @request.reload.finalization_status
      assert_equal "Privacy::AccountErasure::ProtectedAccount", @request.finalization_reason
      assert_not @request.claim_finalization!
      @request.update!(finalization_attempts: 4, finalization_retry_at: nil)
      assert @request.claim_finalization!
      @request.fail_finalization!(error: IOError.new("private failure"))
      assert_equal "failed", @request.reload.finalization_status
      assert AccountDeletionRequest.unhealthy?
    end
  end

  test "notice kinds cannot become SQL identifiers outside the fixed allowlist" do
    assert_raises(ArgumentError) { @request.claim_notice!("requested OR 1=1") }
    assert_raises(ArgumentError) { AccountDeletionRequest.deliverable_notices("invalid") }
  end
end
