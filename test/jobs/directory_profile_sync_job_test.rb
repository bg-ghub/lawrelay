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

  test "logs one result for each completed attempt using only the job identifier and fixed outcome codes" do
    user = users(:one)
    outcomes = { updated: :updated, unchanged: :unchanged, ineligible: :skipped, stale: :skipped,
      empty: :skipped, identity_mismatch: :skipped, missing_profile: :skipped, invalid_data: :failed }
    capture_refresh_log do |output|
      expected = outcomes.map do |status, outcome|
        job = Directory::ProfileSyncJob.new(user.id)
        with_sync_result(status) { job.perform_now }
        marker(job, 1, outcome, status)
      end
      job = Directory::ProfileSyncJob.new(-1)
      job.perform_now
      expected << marker(job, 1, :skipped, :missing_user)
      assert_equal expected, output.string.lines.map(&:chomp)
    end
  end

  test "links an unavailable attempt to its later success" do
    job = Directory::ProfileSyncJob.new(users(:one).id)
    capture_refresh_log do |output|
      with_sync_result(:unavailable) { job.perform_now }
      assert_equal 1, enqueued_jobs.size
      with_sync_result(:unchanged) { ActiveJob::Base.execute(enqueued_jobs.shift) }
      assert_equal [ marker(job, 1, :retrying, :unavailable), marker(job, 2, :unchanged, :unchanged) ],
        output.string.lines.map(&:chomp)
    end
    assert_empty enqueued_jobs
  end

  test "exhausting retries logs one final failure and preserves the queue failure" do
    job = Directory::ProfileSyncJob.new(users(:one).id)
    capture_refresh_log do |output|
      with_sync_result(:unavailable) do
        job.perform_now
        ActiveJob::Base.execute(enqueued_jobs.shift)
        assert_raises(Directory::ProfileSyncJob::TemporarilyUnavailable) { ActiveJob::Base.execute(enqueued_jobs.shift) }
      end
      assert_equal [ marker(job, 1, :retrying, :unavailable), marker(job, 2, :retrying, :unavailable),
        marker(job, 3, :failed, :unavailable) ], output.string.lines.map(&:chomp)
    end
    assert_empty enqueued_jobs
  end

  test "unexpected results and exceptions never copy provider details into the outcome" do
    job = Directory::ProfileSyncJob.new(users(:one).id)
    other = Directory::ProfileSyncJob.new(users(:two).id)
    capture_refresh_log do |output|
      with_sync_result("private@example.test") { job.perform_now }
      with_sync_result(nil, error: IOError.new("private provider details")) do
        assert_raises(IOError) { other.perform_now }
      end
      assert_equal [ marker(job, 1, :failed, :unexpected_result), marker(other, 1, :failed, :exception) ],
        output.string.lines.map(&:chomp)
    end
  end

  test "a rejected retry enqueue is recorded as failed" do
    job = Directory::ProfileSyncJob.new(users(:one).id)
    job.define_singleton_method(:enqueue) { |*| false }
    capture_refresh_log do |output|
      with_sync_result(:unavailable) { job.perform_now }
      assert_equal [ marker(job, 1, :failed, :retry_enqueue_failed) ], output.string.lines.map(&:chomp)
    end
    assert_empty enqueued_jobs
  end

  test "if the adapter raises during retry enqueue the queue still sees the exception" do
    job = Directory::ProfileSyncJob.new(users(:one).id)
    job.define_singleton_method(:enqueue) { |*| raise IOError, "internal adapter details" }
    capture_refresh_log do |output|
      with_sync_result(:unavailable) { assert_raises(IOError) { job.perform_now } }
      assert_equal [ marker(job, 1, :failed, :retry_enqueue_failed) ], output.string.lines.map(&:chomp)
    end
  end

  private

  def marker(job, attempt, outcome, reason)
    "directory.profile_refresh job_id=#{job.job_id} attempt=#{attempt} outcome=#{outcome} reason=#{reason}"
  end

  def capture_refresh_log
    previous = Rails.logger
    output = StringIO.new
    Rails.logger = ActiveSupport::Logger.new(output)
    yield output
  ensure
    Rails.logger = previous
  end

  def with_sync_result(status, calls: [], error: nil)
    original = Directory::ProfileSync.method(:call)
    Directory::ProfileSync.define_singleton_method(:call) do |user:|
      calls << user.id
      raise error if error
      Directory::ProfileSync::Result.new(status:, changed_fields: [])
    end
    yield
  ensure
    Directory::ProfileSync.define_singleton_method(:call, original)
  end
end
