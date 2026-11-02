require "test_helper"
require_relative "../support/marketplace_test_factory"

class AccountDeletionNoticeJobTest < ActiveJob::TestCase
  include MarketplaceTestFactory
  self.fixture_table_names = []

  setup do
    @account = create_marketplace_account(prefix: "deletion-notice")
    @member = @account.user
    ActionMailer::Base.deliveries.clear
  end

  test "the request notice reaches the professional address once and uses only an id in job arguments" do
    request = schedule
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_equal "sent", request.reload.requested_email_status
    assert_equal [ @member.email_address ], ActionMailer::Base.deliveries.sole.to
    assert_equal "account-deletion-#{request.id}-requested@#{SiteHosts.app_host.split(':').first}", ActionMailer::Base.deliveries.sole.message_id
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_equal 1, request.reload.requested_email_attempts
    refute_includes enqueued_jobs.to_s, @member.email_address
  end

  test "a cancelled cycle skips its old request notice and confirms cancellation" do
    request = schedule
    Accounts::Deletion.cancel!(user: @member, current_session: @member.sessions.create!, password: "password1234")
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_empty ActionMailer::Base.deliveries
    AccountDeletionNoticeJob.perform_now(request.id, "cancelled")
    assert_equal "sent", request.reload.cancelled_email_status
    assert_equal [ @member.email_address ], ActionMailer::Base.deliveries.sole.to
    assert_equal I18n.t("account_deletion_mail.cancelled.subject", locale: :en), ActionMailer::Base.deliveries.sole.subject
  end

  test "a new pending cycle suppresses a stale cancellation notice" do
    request = schedule
    Accounts::Deletion.cancel!(user: @member, current_session: @member.sessions.create!, password: "password1234")
    schedule
    AccountDeletionNoticeJob.perform_now(request.id, "cancelled")
    assert_empty ActionMailer::Base.deliveries
    assert_equal "skipped", request.reload.cancelled_email_status
  end

  test "an address change suppresses the pending notice" do
    request = schedule
    @member.update!(email_address: "changed-deletion-notice@example.test")
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_equal "skipped", request.reload.requested_email_status
    assert_empty ActionMailer::Base.deliveries
  end

  test "an erased account does not receive an old notice" do
    request = schedule
    @member.update_columns(erased_at: Time.current)
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_empty ActionMailer::Base.deliveries
    assert_equal "skipped", request.reload.requested_email_status
  end

  test "mail failure remains in the bounded persistent outbox and can be retried" do
    request = schedule
    original = AccountDeletionMailer.method(:requested)
    AccountDeletionMailer.define_singleton_method(:requested) { |_request| raise IOError, "private transport information" }
    AccountDeletionNoticeJob.perform_now(request.id, "requested")
    assert_equal "pending", request.reload.requested_email_status
    assert_equal "IOError", request.requested_email_reason
    assert request.requested_email_retry_at
    assert @member.reload.deletion_pending?
    assert_empty ActionMailer::Base.deliveries
    AccountDeletionMailer.define_singleton_method(:requested, original)
    travel 2.minutes do
      AccountDeletionNoticeJob.perform_now(request.id, "requested")
    end
    assert_equal "sent", request.reload.requested_email_status
    assert_equal 2, request.requested_email_attempts
    assert_equal 1, ActionMailer::Base.deliveries.size
  ensure
    AccountDeletionMailer.define_singleton_method(:requested, original) if original
  end

  test "unknown requests or notice kinds do not send mail" do
    AccountDeletionNoticeJob.perform_now(-1, "requested")
    AccountDeletionNoticeJob.perform_now(schedule.id, "unsupported")
    assert_empty ActionMailer::Base.deliveries
  end

  private

  def schedule
    Accounts::Deletion.schedule!(user: @member.reload, current_session: @member.sessions.create!, password: "password1234")
  end
end
