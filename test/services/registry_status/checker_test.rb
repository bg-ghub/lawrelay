require "test_helper"
require_relative "../../support/marketplace_test_factory"

class RegistryStatus::CheckerTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  setup do
    @account = create_marketplace_account(prefix: "registry-check", verified: false, email_verified: false)
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: "Persisted Directory Identity", directory_email: "expected@example.test")
    clear_enqueued_jobs
  end

  test "catalog includes pending and suspended members and deduplicates valid company numbers" do
    second = users(:two)
    second.update!(suspended_at: Time.current)
    duplicate_firm = Firm.create!(name: "Shared number", enterprise_number: "BE #{@account.firm.enterprise_number}")
    second.memberships.create!(firm: duplicate_firm)
    second.create_lawyer_profile!(bar_association: "OVB", bar_number: "registry-duplicate",
      directory_profile_url: @account.profile.directory_profile_url.sub("www.advocaat.be", "advocaat.be"),
      directory_name: @account.profile.directory_name, directory_email: @account.profile.directory_email)
    admin = create_marketplace_account(prefix: "registry-admin", system_role: "admin")
    admin.profile.update!(directory_profile_url: profile_url)
    erased = create_marketplace_account(prefix: "registry-erased")
    erased.profile.update!(directory_profile_url: profile_url)
    erased.user.update!(erased_at: Time.current)
    invalid_firm = Firm.create!(name: "Invalid number", enterprise_number: "123")
    users(:one).memberships.create!(firm: invalid_firm)

    targets = RegistryStatus::Targets.all
    assert_equal 3, targets.size
    assert_equal %w[directory directory kbo], targets.map(&:source).sort
    directory = targets.find { |target| target.lawyer_profile_id == @account.profile.id }
    assert_equal "Persisted Directory Identity", directory.full_name
    assert_equal "expected@example.test", directory.expected_email
    assert_equal @account.profile.id, directory.lawyer_profile_id
    assert_equal @account.firm.id, targets.find { |target| target.source == "kbo" }.firm_id
  end

  test "members sharing a canonical directory URL each have their persisted identity checked" do
    second = users(:two)
    second.update!(suspended_at: Time.current)
    second_profile = second.create_lawyer_profile!(bar_association: "OVB", bar_number: "second-directory-identity",
      directory_profile_url: @account.profile.directory_profile_url.sub("www.advocaat.be", "advocaat.be"),
      directory_name: "Different Persisted Identity", directory_email: "second-expected@example.test")
    calls = []
    outcome = ->(arguments) { result(arguments.fetch(:full_name) == @account.profile.directory_name ? :active : :changed) }
    with_lookups(kbo: :ok, directory: outcome, calls:) do
      run = execute_claimed_run(Time.current.utc.to_date)
      assert_equal 1, run.new_findings_count
      assert_equal second_profile.id, run.findings.sole.fetch("lawyer_profile_id")
    end
    directory_calls = calls.select { |source, _| source == :directory }.map(&:last)
    assert_equal 2, directory_calls.size
    assert_equal 1, directory_calls.map { |arguments| arguments.fetch(:profile_url) }.uniq.size
    assert_equal [ @account.profile.directory_email, second_profile.directory_email ].sort,
      directory_calls.map { |arguments| arguments.fetch(:expected_email) }.sort
    assert_equal 2, RegistryStatusCheck.where(source: "directory").count
    assert_equal 2, RegistryStatusCheck.where(source: "directory").distinct.count(:target_digest)
    assert_equal "changed", RegistryStatusCheck.find_by!(lawyer_profile: second_profile).issue_status
  end

  test "outages preserve issues unchanged findings are quiet and definitive resolution permits recurrence" do
    domain_records = [ @account.user, @account.firm, @account.profile, @account.user.sessions.create! ]
    before = domain_records.map(&:attributes)
    day = Time.current.utc.to_date

    first = execute(day, kbo: :inactive, directory: :not_listed)
    assert_equal 2, first.new_findings_count
    assert_equal "pending", first.alert_status
    assert RegistryStatusCheck.all.all? { |check| check.last_alerted_at.nil? }
    assert_equal 0, execute(day + 1, kbo: :unavailable, directory: :unavailable).new_findings_count
    assert_equal %w[inactive not_listed], RegistryStatusCheck.order(:source).pluck(:issue_status).sort
    assert_equal %w[inactive not_listed], RegistryStatusCheck.order(:source).pluck(:last_definitive_status).sort
    assert_equal 0, execute(day + 2, kbo: :inactive, directory: :not_listed).new_findings_count
    assert_equal 0, execute(day + 3, kbo: :ok, directory: :active).new_findings_count
    assert_empty RegistryStatusCheck.issues
    assert_equal 2, execute(day + 4, kbo: :inactive, directory: :not_listed).new_findings_count
    assert_equal before, domain_records.map { |record| record.reload.attributes }
    assert_enqueued_jobs 0
    state = [ RegistryStatusCheck.all.map(&:attributes), first.reload.attributes ].to_json
    [ @account.user.full_name, @account.user.email_address, @account.profile.directory_email,
      @account.profile.directory_profile_url, @account.firm.enterprise_number ].each do |private_value|
      assert_not_includes state, private_value
    end
  end

  test "KBO missing and invalid responses never become inactive or clear a previous inactive finding" do
    day = Time.current.utc.to_date
    execute(day, kbo: :inactive, directory: :active)
    [ :not_found, :invalid, :unavailable ].each_with_index do |status, index|
      run = execute(day + index + 1, kbo: status, directory: :active)
      assert_equal 0, run.new_findings_count
      check = RegistryStatusCheck.find_by!(source: "kbo")
      assert_equal status.to_s, check.status
      assert_equal "inactive", check.issue_status
      assert_equal "inactive", check.last_definitive_status
    end
  end

  test "a duplicate daily invocation does not fetch again or enqueue another consolidated message" do
    calls = []
    with_lookups(kbo: :inactive, directory: :changed, calls:) do
      DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601)
      DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601)
    end
    assert_equal [ :kbo, :directory ], calls.map(&:first)
    assert_equal 1, RegistryStatusRun.count
    assert_equal 2, RegistryStatusRun.first.checked_count
    assert_enqueued_with(job: RegistryStatusAlertJob, args: [ RegistryStatusRun.first.id ])
    assert_enqueued_jobs 1
  end

  test "a retried partial run preserves committed findings and skips completed provider requests" do
    calls = []
    with_lookups(kbo: :inactive, directory: ->(*) { raise IOError, "synthetic interrupted request" }, calls:) do
      assert_raises(IOError) { DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601) }
    end
    run = RegistryStatusRun.first
    assert_equal "pending", run.status
    assert_equal 1, run.checked_count
    assert_equal 1, run.findings.size
    assert_nil run.alert_status

    with_lookups(kbo: :inactive, directory: :active, calls:) do
      DailyRegistryStatusJob.new.perform(run.run_on.iso8601)
    end
    assert_equal [ :kbo, :directory, :directory ], calls.map(&:first)
    assert_equal "completed", run.reload.status
    assert_equal 1, run.findings.size
    assert_equal "pending", run.alert_status
    assert_enqueued_jobs 1
  end

  test "directory details changed during the fetch cannot persist obsolete evidence" do
    old_url = @account.profile.directory_profile_url
    run = nil
    with_lookups(kbo: :ok, directory: ->(*) { @account.profile.update!(directory_profile_url: profile_url); result(:not_listed) }) do
      run = execute_claimed_run(Time.current.utc.to_date)
    end
    assert_equal 2, run.checked_count
    assert_equal "completed", run.status
    assert_equal 0, run.new_findings_count
    assert_not RegistryStatusCheck.exists?(source: "directory")
    assert_not_equal old_url, @account.profile.reload.directory_profile_url
  end

  test "erasure during a provider request cannot persist a finding for the former member" do
    with_lookups(kbo: ->(*) { @account.user.update!(erased_at: Time.current); result(:inactive) }, directory: :not_listed) do
      run = execute_claimed_run(Time.current.utc.to_date)
      assert_equal 0, run.new_findings_count
      assert_nil run.alert_status
    end
    assert_empty RegistryStatusCheck.all
  end

  test "requests are sequential throttled and chunked with durable same-day progress" do
    51.times do |index|
      base = 20_000_000 + index
      firm = Firm.create!(name: "Bounded target #{index}", enterprise_number: format("%08d%02d", base, 97 - (base % 97)))
      @account.user.memberships.create!(firm:)
    end
    run = RegistryStatusRun.create!(run_on: Time.current.utc.to_date)
    sleeps = []
    calls = []
    with_lookups(kbo: :ok, directory: :active, calls:) do
      first_token = run.claim!
      assert_nil run.reload.claim!
      assert_equal :continue, RegistryStatus::Checker.new(run:, token: first_token, sleeper: ->(duration) { sleeps << duration }).call
      assert_equal 50, run.reload.checked_count
      assert_equal "pending", run.status
      assert_equal :completed, RegistryStatus::Checker.new(run:, token: run.claim!, sleeper: ->(duration) { sleeps << duration }).call
    end
    assert_equal 53, calls.size
    assert_equal 53, run.reload.checked_target_digests.uniq.size
    assert_equal 53, run.checked_count
    assert_equal 51, sleeps.size
    assert sleeps.all? { |duration| duration == RegistryStatus::Checker::REQUEST_INTERVAL }
  end

  test "reconciler closes missed old days without replaying provider requests and recovers alerts" do
    now = Time.current.change(hour: 9)
    old_pending = RegistryStatusRun.create!(run_on: now.utc.to_date - 2, status: "pending")
    old_running = RegistryStatusRun.create!(run_on: now.utc.to_date - 1, status: "running", lease_expires_at: now - 1.minute)
    completed = execute(now.utc.to_date, kbo: :inactive, directory: :active)
    ReconcileRegistryStatusJob.new.perform(now:)
    assert_enqueued_jobs 1
    assert_enqueued_with(job: RegistryStatusAlertJob, args: [ completed.id ])
    assert_equal "completed", old_pending.reload.status
    assert_equal "completed", old_running.reload.status
    assert_equal 0, old_pending.checked_count
    assert_equal 0, old_running.checked_count
  end

  test "day rollover preserves already committed findings and catches up today's missed scheduler tick" do
    now = Time.current.change(hour: 9)
    previous = execute(now.utc.to_date - 2, kbo: :inactive, directory: :active)
    previous.update!(status: "pending", completed_at: nil, alert_status: nil)
    with_lookups(kbo: ->(*) { flunk "Must not replay missed old-day requests" }, directory: ->(*) { flunk "Must not replay missed old-day requests" }) do
      DailyRegistryStatusJob.new.perform(previous.run_on.iso8601)
    end
    assert_equal "completed", previous.reload.status
    assert_equal 1, previous.new_findings_count
    assert_equal "pending", previous.alert_status
    clear_enqueued_jobs
    ReconcileRegistryStatusJob.new.perform(now:)
    assert_enqueued_jobs 2
    assert_enqueued_with(job: RegistryStatusAlertJob, args: [ previous.id ])
    assert_enqueued_with(job: DailyRegistryStatusJob, args: [ now.utc.to_date.iso8601 ])
  end

  test "changed expected identity clears previous definitive evidence before an outage" do
    target = RegistryStatus::Targets.all.find { |candidate| candidate.source == "directory" }
    check = RegistryStatusCheck.new(source: target.source, target_digest: target.digest, lawyer_profile_id: target.lawyer_profile_id)
    check.record_result!(outcome: :not_listed, checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    check.record_result!(outcome: :unavailable, checked_at: Time.current, run_on: Date.current + 1, identity_digest: "changed-identity-digest")
    assert_nil check.issue_status
    assert_nil check.last_definitive_status
    assert_nil check.last_definitive_at
    assert_nil check.issue_since
  end

  private

  def execute(day, kbo:, directory:)
    with_lookups(kbo:, directory:) { execute_claimed_run(day) }
  end

  def execute_claimed_run(day)
    run = RegistryStatusRun.create!(run_on: day)
    assert_equal :completed, RegistryStatus::Checker.new(run:, token: run.claim!, sleeper: ->(*) { }).call
    run.reload
  end

  def profile_url
    "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
  end

  def result(status)
    Struct.new(:status).new(status)
  end

  def with_lookups(kbo:, directory:, calls: [])
    originals = [ BusinessRegistry::PublicLookup.method(:call), Directory::StatusCheck.method(:call) ]
    result_factory = method(:result)
    BusinessRegistry::PublicLookup.define_singleton_method(:call) do |**arguments|
      calls << [ :kbo, arguments ]
      kbo.respond_to?(:call) ? kbo.call(arguments) : result_factory.call(kbo)
    end
    Directory::StatusCheck.define_singleton_method(:call) do |**arguments|
      calls << [ :directory, arguments ]
      directory.respond_to?(:call) ? directory.call(arguments) : result_factory.call(directory)
    end
    yield
  ensure
    BusinessRegistry::PublicLookup.define_singleton_method(:call, originals[0]) if originals
    Directory::StatusCheck.define_singleton_method(:call, originals[1]) if originals
  end
end
