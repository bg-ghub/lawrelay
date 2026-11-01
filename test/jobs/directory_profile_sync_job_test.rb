require "test_helper"

class DirectoryProfileSyncJobTest < ActiveJob::TestCase
  test "refreshes only the requested existing account through the normal service" do
    user = users(:one)
    calls = []
    with_sync_result(:unchanged, calls:) do
      Directory::ProfileSyncJob.perform_now(user.id)
      Directory::ProfileSyncJob.perform_now(-1)
    end
    assert_equal [ user.id ], calls
  end

  test "a transient provider failure retries without retaining provider details" do
    calls = []
    with_sync_result(:unavailable, calls:) do
      assert_enqueued_with(job: Directory::ProfileSyncJob, args: [ users(:one).id ]) do
        Directory::ProfileSyncJob.perform_now(users(:one).id)
      end
    end
    assert_equal [ users(:one).id ], calls
  end

  test "empty identity and stale results do not send notifications or retry nontransient failures" do
    calls = []
    %i[empty identity_mismatch ineligible stale invalid_data].each do |status|
      with_sync_result(status, calls:) do
        assert_no_enqueued_jobs { Directory::ProfileSyncJob.perform_now(users(:one).id) }
      end
    end
    assert_equal 5, calls.size
  end

  private

  def with_sync_result(status, calls:)
    original = Directory::ProfileSync.method(:call)
    Directory::ProfileSync.define_singleton_method(:call) do |user:|
      calls << user.id
      Directory::ProfileSync::Result.new(status:, changed_fields: [])
    end
    yield
  ensure
    Directory::ProfileSync.define_singleton_method(:call, original)
  end
end
