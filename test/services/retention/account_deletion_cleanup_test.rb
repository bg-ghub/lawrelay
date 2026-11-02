require "test_helper"
require_relative "../../support/marketplace_test_factory"

class AccountDeletionCleanupTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  self.fixture_table_names = []

  test "unverified registration cleanup never removes a pending grace-period account" do
    account = create_marketplace_account(prefix: "retained-deletion", verified: false, email_verified: false)
    user = account.user
    request = Accounts::Deletion.schedule!(user:, current_session: user.sessions.create!, password: "password1234")
    user.update_columns(created_at: 3.months.ago, updated_at: 40.days.ago)
    account.profile.update_columns(created_at: 3.months.ago, updated_at: 40.days.ago)
    Retention::Cleanup.new(dry_run: false).call
    assert User.exists?(user.id)
    assert AccountDeletionRequest.exists?(request.id)
  end

  test "terminal deletion history follows the resolved-request period and holds" do
    account = create_marketplace_account(prefix: "deletion-history")
    user = account.user
    request = Accounts::Deletion.schedule!(user:, current_session: user.sessions.create!, password: "password1234")
    Accounts::Deletion.cancel!(user:, current_session: user.sessions.create!, password: "password1234")
    request.update!(cancelled_email_status: "sent", cancelled_email_sent_at: Time.current)
    request.update_columns(requested_at: 3.years.ago, scheduled_at: 3.years.ago + 30.days, cancelled_at: 2.years.ago - 1.day)
    admin = create_marketplace_account(prefix: "history-hold-admin", system_role: "admin").user
    admin.update!(admin_mfa_enabled_at: Time.current, admin_mfa_secret_ciphertext: "synthetic-secret")
    hold = RetentionHold.create!(subject: user, actor: admin, reason: "Synthetic history hold", expires_at: 30.days.from_now)

    Retention::Cleanup.new(dry_run: false).call
    assert AccountDeletionRequest.exists?(request.id)
    hold.destroy!
    result = Retention::Cleanup.new(dry_run: false).call
    assert_equal 1, result.account_deletion_requests
    assert_not AccountDeletionRequest.exists?(request.id)
    assert user.reload.active?
  end

  test "unresolved notice failures preserve terminal history for operational review" do
    account = create_marketplace_account(prefix: "deletion-failed-history")
    user = account.user
    request = Accounts::Deletion.schedule!(user:, current_session: user.sessions.create!, password: "password1234")
    Accounts::Deletion.cancel!(user:, current_session: user.sessions.create!, password: "password1234")
    request.update!(cancelled_email_status: "failed")
    request.update_columns(requested_at: 3.years.ago, scheduled_at: 3.years.ago + 30.days, cancelled_at: 2.years.ago - 1.day)

    Retention::Cleanup.new(dry_run: false).call
    assert AccountDeletionRequest.exists?(request.id)
  end
end
