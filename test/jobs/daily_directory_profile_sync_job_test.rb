require "test_helper"
require_relative "../support/marketplace_test_factory"

class DailyDirectoryProfileSyncJobTest < ActiveJob::TestCase
  include MarketplaceTestFactory

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  test "daily dispatcher schedules linked active members at one-second intervals and skips other accounts" do
    first = linked_account("dailyfirst")
    second = linked_account("dailysecond")
    suspended = linked_account("dailysuspended")
    suspended.user.update_columns(suspended_at: Time.current)
    erased = linked_account("dailyerased")
    erased.user.update_columns(erased_at: Time.current)
    admin = linked_account("dailyadmin")
    admin.user.update_columns(system_role: "admin")
    rejected = linked_account("dailyrejected")
    rejected.profile.update_columns(verification_status: "rejected")
    unmatched = linked_account("dailyunmatched")
    unmatched.profile.update_columns(directory_profile_id: nil)
    create_marketplace_account(prefix: "dailyunlinked")

    travel_to Time.utc(2026, 11, 1, 5, 30) do
      assert_enqueued_jobs 2, only: Directory::ProfileSyncJob do
        DailyDirectoryProfileSyncJob.perform_now
      end
      jobs = enqueued_jobs.select { |job| job[:job] == Directory::ProfileSyncJob }
      assert_equal [ [ first.user.id ], [ second.user.id ] ], jobs.map { |job| job[:args] }
      assert_equal [ Time.current.to_f, (Time.current + 1.second).to_f ], jobs.map { |job| job[:at] }
    end
  end

  test "batches at most fifty accounts and schedules a cursor continuation" do
    accounts = (1..51).map { |index| linked_account("dailybatch#{index}") }
    travel_to Time.utc(2026, 11, 1, 5, 30) do
      assert_enqueued_jobs 50, only: Directory::ProfileSyncJob do
        assert_enqueued_with(job: DailyDirectoryProfileSyncJob,
          args: [ accounts[49].user.id, "2026-11-01" ], at: Time.current + 50.seconds) do
          DailyDirectoryProfileSyncJob.perform_now
        end
      end
      jobs = enqueued_jobs.select { |job| job[:job] == Directory::ProfileSyncJob }
      assert_equal accounts.first(50).map { |account| [ account.user.id ] }, jobs.map { |job| job[:args] }
      clear_enqueued_jobs
      assert_enqueued_jobs 1, only: Directory::ProfileSyncJob do
        DailyDirectoryProfileSyncJob.perform_now(accounts[49].user.id, "2026-11-01")
      end
      assert_equal [ accounts.last.user.id ], enqueued_jobs.find { |job| job[:job] == Directory::ProfileSyncJob }[:args]
    end
  end

  test "old and future daily dispatches do not duplicate a current day's refresh" do
    linked_account("dayboundedsync")
    travel_to Time.utc(2026, 11, 1, 5, 30) do
      assert_no_enqueued_jobs do
        DailyDirectoryProfileSyncJob.perform_now(0, "2026-10-31")
        DailyDirectoryProfileSyncJob.perform_now(0, "2026-11-02")
      end
    end
  end

  private

  def linked_account(prefix)
    account = create_marketplace_account(prefix:)
    account.profile.update!(directory_profile_url: PROFILE_URL, directory_profile_id: SecureRandom.uuid,
      directory_name: account.user.full_name, directory_email: account.user.email_address, directory_checked_at: Time.current)
    account
  end
end
