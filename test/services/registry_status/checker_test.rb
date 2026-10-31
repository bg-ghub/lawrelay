require "test_helper"
require_relative "../../support/marketplace_test_factory"

class RegistryStatus::CheckerTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  setup do
    @account = create_marketplace_account(prefix: "registry-check", verified: false, email_verified: false)
    @account.profile.update!(directory_profile_url: profile_url,
      directory_name: "Persisted Directory Identity", directory_email: "expected@example.test")
    clear_enqueued_jobs
  end

  test "catalog checks pending and suspended members individually and excludes other identities" do
    second = users(:two)
    second.update!(suspended_at: Time.current)
    second.create_lawyer_profile!(bar_association: "OVB", bar_number: "registry-duplicate",
      directory_profile_url: @account.profile.directory_profile_url.sub("www.advocaat.be", "advocaat.be"),
      directory_name: @account.profile.directory_name, directory_email: @account.profile.directory_email)
    admin = create_marketplace_account(prefix: "registry-admin", system_role: "admin")
    admin.profile.update!(directory_profile_url: profile_url)
    erased = create_marketplace_account(prefix: "registry-erased")
    erased.profile.update!(directory_profile_url: profile_url)
    erased.user.update!(erased_at: Time.current)

    targets = RegistryStatus::Targets.all
    assert_equal 2, targets.size
    assert_equal [ "directory" ], targets.map(&:source).uniq
    assert targets.all? { |target| target.firm_id.nil? }
    assert_equal 2, targets.map(&:digest).uniq.size
    directory = targets.find { |target| target.lawyer_profile_id == @account.profile.id }
    assert_equal "Persisted Directory Identity", directory.full_name
    assert_equal "expected@example.test", directory.expected_email
  end

  test "members sharing a canonical directory URL each have their persisted identity checked" do
    second_profile = add_profile(users(:two), name: "Different Persisted Identity", email: "second-expected@example.test",
      url: @account.profile.directory_profile_url.sub("www.advocaat.be", "advocaat.be"))
    calls = []
    outcome = ->(arguments) { result(arguments.fetch(:full_name) == @account.profile.directory_name ? :active : :changed) }
    with_lookup(directory: outcome, calls:) do
      run = execute_claimed_run(Time.current.utc.to_date)
      assert_equal 1, run.new_findings_count
      assert_equal second_profile.id, run.findings.sole.fetch("lawyer_profile_id")
    end
    assert_equal 2, calls.size
    assert_equal 1, calls.map { |arguments| arguments.fetch(:profile_url) }.uniq.size
    assert_equal [ @account.profile.directory_email, second_profile.directory_email ].sort,
      calls.map { |arguments| arguments.fetch(:expected_email) }.sort
    assert_equal 2, RegistryStatusCheck.where(source: "directory").distinct.count(:target_digest)
    assert_equal "changed", RegistryStatusCheck.find_by!(lawyer_profile: second_profile).issue_status
  end

  test "outages preserve issues unchanged findings are quiet and resolution permits recurrence" do
    domain_records = [ @account.user, @account.firm, @account.profile, @account.user.sessions.create! ]
    before = domain_records.map(&:attributes)
    day = Time.current.utc.to_date

    first = execute(day, directory: :not_listed)
    assert_equal 1, first.new_findings_count
    assert_equal "pending", first.alert_status
    assert RegistryStatusCheck.all.all? { |check| check.last_alerted_at.nil? }
    assert_equal 0, execute(day + 1, directory: :unavailable).new_findings_count
    check = RegistryStatusCheck.sole
    assert_equal "not_listed", check.issue_status
    assert_equal "not_listed", check.last_definitive_status
    assert_equal 0, execute(day + 2, directory: :not_listed).new_findings_count
    assert_equal 0, execute(day + 3, directory: :active).new_findings_count
    assert_empty RegistryStatusCheck.issues
    assert_equal 1, execute(day + 4, directory: :not_listed).new_findings_count
    assert_equal before, domain_records.map { |record| record.reload.attributes }
    assert_enqueued_jobs 0
    state = [ RegistryStatusCheck.all.map(&:attributes), first.reload.attributes ].to_json
    [ @account.user.full_name, @account.user.email_address, @account.profile.directory_email,
      @account.profile.directory_profile_url, @account.firm.enterprise_number ].each do |private_value|
      assert_not_includes state, private_value
    end
  end

  test "not listed changed and unavailable remain distinct and unexpected results are unavailable" do
    day = Time.current.utc.to_date
    assert_equal 1, execute(day, directory: :not_listed).new_findings_count
    assert_equal 1, execute(day + 1, directory: :changed).new_findings_count
    assert_equal "changed", RegistryStatusCheck.sole.issue_status
    assert_equal 0, execute(day + 2, directory: :unexpected).new_findings_count
    assert_equal "unavailable", RegistryStatusCheck.sole.status
    assert_equal "changed", RegistryStatusCheck.sole.last_definitive_status
  end

  test "a duplicate daily invocation does not fetch again or enqueue another summary" do
    calls = []
    with_lookup(directory: :changed, calls:) do
      DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601)
      DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601)
    end
    assert_equal 1, calls.size
    assert_equal 1, RegistryStatusRun.count
    assert_equal 1, RegistryStatusRun.first.checked_count
    assert_enqueued_with(job: RegistryStatusAlertJob, args: [ RegistryStatusRun.first.id ])
    assert_enqueued_jobs 1
  end

  test "a retried partial run preserves findings and skips completed profile requests" do
    second_profile = add_profile(users(:two))
    calls = []
    interrupted = lambda do |arguments|
      raise IOError, "synthetic interrupted request" if arguments[:profile_url] == second_profile.directory_profile_url

      result(:changed)
    end
    with_lookup(directory: interrupted, calls:) do
      assert_raises(IOError) { DailyRegistryStatusJob.new.perform(Time.current.utc.to_date.iso8601) }
    end
    run = RegistryStatusRun.first
    assert_equal "pending", run.status
    assert_equal 1, run.checked_count
    assert_equal 1, run.findings.size
    assert_nil run.alert_status

    with_lookup(directory: :active, calls:) { DailyRegistryStatusJob.new.perform(run.run_on.iso8601) }
    assert_equal [ @account.profile.directory_profile_url, second_profile.directory_profile_url, second_profile.directory_profile_url ],
      calls.map { |arguments| arguments[:profile_url] }
    assert_equal "completed", run.reload.status
    assert_equal 1, run.findings.size
    assert_equal "pending", run.alert_status
    assert_enqueued_jobs 1
  end

  test "the first daily rerun after legacy cleanup retains completed directory dedup state" do
    run = execute(Time.current.utc.to_date, directory: :changed)
    check = RegistryStatusCheck.sole
    original_check = check.attributes
    digest = RegistryStatusCheck.digest("kbo", @account.firm.enterprise_number)
    legacy = RegistryStatusCheck.new(source: "kbo", target_digest: digest, identity_digest: digest,
      status: "inactive", issue_status: "inactive", issue_since: Time.current)
    legacy.save!(validate: false)
    run.update!(findings: run.findings + [ legacy.finding_snapshot ],
      checked_target_digests: run.checked_target_digests + [ digest ])

    RegistryStatus::Cleanup.new.call
    with_lookup(directory: ->(*) { flunk "Completed directory targets must not be fetched again" }) do
      DailyRegistryStatusJob.new.perform(run.run_on.iso8601)
    end

    assert_equal original_check, check.reload.attributes
    assert_equal [ check.finding_snapshot ], run.reload.findings
    assert_equal [ check.target_digest ], run.checked_target_digests
    assert_equal "pending", run.alert_status
    assert_equal "completed", run.status
    assert_enqueued_jobs 0
  end

  test "directory details changed during the fetch cannot persist obsolete evidence" do
    old_url = @account.profile.directory_profile_url
    run = nil
    with_lookup(directory: ->(*) { @account.profile.update!(directory_profile_url: profile_url); result(:not_listed) }) do
      run = execute_claimed_run(Time.current.utc.to_date)
    end
    assert_equal 1, run.checked_count
    assert_equal "completed", run.status
    assert_equal 0, run.new_findings_count
    assert_empty RegistryStatusCheck.all
    assert_not_equal old_url, @account.profile.reload.directory_profile_url
  end

  test "erasure during a directory request cannot persist a finding for the former member" do
    with_lookup(directory: ->(*) { @account.user.update!(erased_at: Time.current); result(:not_listed) }) do
      run = execute_claimed_run(Time.current.utc.to_date)
      assert_equal 0, run.new_findings_count
      assert_nil run.alert_status
    end
    assert_empty RegistryStatusCheck.all
  end

  test "requests are sequential throttled and chunked with durable same day progress" do
    51.times do |index|
      user = User.create!(first_name: "Bounded", last_name: "Member #{index}",
        email_address: "bounded-directory-#{index}@example.test", password: "password1234")
      add_profile(user)
    end
    run = RegistryStatusRun.create!(run_on: Time.current.utc.to_date)
    sleeps = []
    calls = []
    with_lookup(directory: :active, calls:) do
      first_token = run.claim!
      assert_nil run.reload.claim!
      assert_equal :continue, RegistryStatus::Checker.new(run:, token: first_token, sleeper: ->(duration) { sleeps << duration }).call
      assert_equal 50, run.reload.checked_count
      assert_equal "pending", run.status
      assert_equal :completed, RegistryStatus::Checker.new(run:, token: run.claim!, sleeper: ->(duration) { sleeps << duration }).call
    end
    assert_equal 52, calls.size
    assert_equal 52, run.reload.checked_target_digests.uniq.size
    assert_equal 52, run.checked_count
    assert_equal 50, sleeps.size
    assert sleeps.all? { |duration| duration == RegistryStatus::Checker::REQUEST_INTERVAL }
  end

  test "reconciler closes missed old days without replaying requests and recovers alerts" do
    now = Time.current.change(hour: 9)
    old_pending = RegistryStatusRun.create!(run_on: now.utc.to_date - 2, status: "pending")
    old_running = RegistryStatusRun.create!(run_on: now.utc.to_date - 1, status: "running", lease_expires_at: now - 1.minute)
    completed = execute(now.utc.to_date, directory: :changed)
    ReconcileRegistryStatusJob.new.perform(now:)
    assert_enqueued_jobs 1
    assert_enqueued_with(job: RegistryStatusAlertJob, args: [ completed.id ])
    assert_equal "completed", old_pending.reload.status
    assert_equal "completed", old_running.reload.status
    assert_equal 0, old_pending.checked_count
    assert_equal 0, old_running.checked_count
  end

  test "day rollover preserves findings and catches up today's missed scheduler tick" do
    now = Time.current.change(hour: 9)
    previous = execute(now.utc.to_date - 2, directory: :changed)
    previous.update!(status: "pending", completed_at: nil, alert_status: nil)
    with_lookup(directory: ->(*) { flunk "Must not replay missed old day requests" }) do
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
    target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == @account.profile.id }
    check = RegistryStatusCheck.new(source: target.source, target_digest: target.digest, lawyer_profile_id: target.lawyer_profile_id)
    check.record_result!(outcome: :not_listed, checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    check.record_result!(outcome: :unavailable, checked_at: Time.current, run_on: Date.current + 1, identity_digest: "changed-identity-digest")
    assert_nil check.issue_status
    assert_nil check.last_definitive_status
    assert_nil check.last_definitive_at
    assert_nil check.issue_since
  end

  private

  def add_profile(user, name: user.full_name, email: user.email_address, url: profile_url)
    user.create_lawyer_profile!(bar_association: "OVB", bar_number: "registry-#{user.id}",
      directory_profile_url: url, directory_name: name, directory_email: email)
  end

  def execute(day, directory:)
    with_lookup(directory:) { execute_claimed_run(day) }
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

  def with_lookup(directory:, calls: [])
    original = Directory::StatusCheck.method(:call)
    original_company = BusinessRegistry::PublicLookup.method(:call)
    result_factory = method(:result)
    BusinessRegistry::PublicLookup.define_singleton_method(:call) { |**| raise "Company lookup must never run" }
    Directory::StatusCheck.define_singleton_method(:call) do |**arguments|
      calls << arguments
      directory.respond_to?(:call) ? directory.call(arguments) : result_factory.call(directory)
    end
    yield
  ensure
    Directory::StatusCheck.define_singleton_method(:call, original) if original
    BusinessRegistry::PublicLookup.define_singleton_method(:call, original_company) if original_company
  end
end
