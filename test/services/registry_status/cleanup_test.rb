require "test_helper"

class RegistryStatus::CleanupTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 10, 31, 12)
  end

  test "erasure removes monitoring state and cancels an unsent empty alert" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile))
    run = completed_run(check:, alert_status: "pending")
    run.update!(alert_claimed_at: @now - 1.minute, alert_retry_at: @now + 1.minute)
    users(:one).update!(erased_at: @now)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_nil run.alert_status
    assert_nil run.alert_claimed_at
    assert_nil run.alert_retry_at
  end

  test "changed directory URLs remove the old digest and scrub its sent run snapshot" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile))
    run = completed_run(check:, alert_status: "sent")
    profile.update!(directory_profile_url: profile_url)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_equal "sent", run.alert_status
  end

  test "changed directory comparison identity removes old monitoring evidence" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile), outcome: "changed")
    run = completed_run(check:, alert_status: "pending")
    profile.update!(directory_email: "replacement@example.test")

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_nil run.alert_status
  end

  test "deleting a profile also scrubs cascading deleted check references" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile))
    run = completed_run(check:, alert_status: "pending")
    profile.destroy!

    RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_nil run.alert_status
  end

  test "erasing one member sharing a directory URL preserves the other member's dedup state" do
    original = member_profile(users(:one))
    remaining = member_profile(users(:two), url: original.directory_profile_url)
    old_check = issue_check(target_for(original))
    check = issue_check(target_for(remaining))
    run = completed_run(check:, alert_status: "pending")
    issue_since = check.issue_since
    users(:one).update!(erased_at: @now)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(old_check.id)
    assert_equal "not_listed", check.reload.issue_status
    assert_equal issue_since, check.issue_since
    assert_equal [ check.finding_snapshot ], run.reload.findings
    assert_equal [ check.target_digest ], run.checked_target_digests
    assert_equal "pending", run.alert_status
    assert_not check.record_result!(outcome: "not_listed", checked_at: @now, run_on: @now.to_date,
      identity_digest: check.identity_digest)
  end

  test "legacy company evidence is removed while directory progress and pending delivery survive" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile))
    legacy = legacy_company_check
    run = completed_run(check:, alert_status: "pending")
    run.update!(findings: [ legacy.finding_snapshot, check.finding_snapshot.merge("firm_id" => 123, "company_name" => "Old company") ],
      checked_target_digests: [ legacy.target_digest, check.target_digest ], checked_count: 2,
      alert_attempts: 2, alert_retry_at: @now + 1.minute, alert_status_reason: "IOError")
    original = check.attributes

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call
    assert_equal 0, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(legacy.id)
    assert_equal original, check.reload.attributes
    assert_equal [ check.finding_snapshot ], run.reload.findings
    assert_equal [ check.target_digest ], run.checked_target_digests
    assert_equal 1, run.checked_count
    assert_equal "pending", run.alert_status
    assert_equal 2, run.alert_attempts
    assert_equal @now + 1.minute, run.alert_retry_at
    assert_equal "IOError", run.alert_status_reason
  end

  test "legacy company only alerts are canceled without recreating a check" do
    legacy = legacy_company_check
    run = completed_run(check: legacy, alert_status: "failed")
    run.update!(alert_claimed_at: @now - 1.minute, alert_retry_at: @now + 1.minute)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_empty RegistryStatusCheck.all
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_nil run.alert_status
    assert_nil run.alert_claimed_at
    assert_nil run.alert_retry_at
  end

  test "resolved check metadata expires after ninety days while an unresolved issue remains" do
    resolved = issue_check(target_for(member_profile(users(:one))), checked_at: @now - 100.days)
    resolved.record_result!(outcome: "active", checked_at: @now - 91.days,
      run_on: (@now - 91.days).to_date, identity_digest: resolved.identity_digest)
    unresolved = issue_check(target_for(member_profile(users(:two))), checked_at: @now - 100.days)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(resolved.id)
    assert RegistryStatusCheck.exists?(unresolved.id)
    assert_equal "not_listed", unresolved.reload.issue_status
  end

  test "a finding committed before a run lock is not removed using an earlier check snapshot" do
    profile = member_profile(users(:one))
    run = completed_run(alert_status: nil)
    injected_check = nil
    inject = -> do
      injected_check = issue_check(target_for(profile))
      run.update!(findings: [ injected_check.finding_snapshot ],
        checked_target_digests: [ injected_check.target_digest ], alert_status: "pending")
    end
    original = RegistryStatusRun.method(:find_each)
    RegistryStatusRun.define_singleton_method(:find_each) do |&block|
      original.call do |record|
        inject.call
        block.call(record)
      end
    end

    RegistryStatus::Cleanup.new(now: @now).call

    assert_equal [ injected_check.finding_snapshot ], run.reload.findings
    assert_equal "pending", run.alert_status
    assert_equal [ injected_check.target_digest ], run.checked_target_digests
  ensure
    RegistryStatusRun.define_singleton_method(:find_each, original) if original
  end

  test "a new profile identity committed before its check lock survives cleanup" do
    profile = member_profile(users(:one))
    check = issue_check(target_for(profile), outcome: "changed")
    inject = -> do
      profile.update!(directory_email: "updated-before-lock@example.test")
      current = target_for(profile)
      check.record_result!(outcome: "not_listed", checked_at: @now, run_on: @now.to_date, identity_digest: current.identity_digest)
    end
    original = RegistryStatusCheck.method(:find_each)
    RegistryStatusCheck.define_singleton_method(:find_each) do |&block|
      original.call do |record|
        inject.call
        block.call(record)
      end
    end

    assert_equal 0, RegistryStatus::Cleanup.new(now: @now).call

    assert_equal "not_listed", check.reload.issue_status
    assert RegistryStatusCheck.relevant.exists?(check.id)
  ensure
    RegistryStatusCheck.define_singleton_method(:find_each, original) if original
  end

  test "old completed metadata expires while pending and failed alert snapshots remain recoverable" do
    check = issue_check(target_for(member_profile(users(:one))))
    without_alert = completed_run(alert_status: nil, age: 91.days)
    sent = completed_run(check:, alert_status: "sent", age: 92.days)
    pending = completed_run(check:, alert_status: "pending", age: 93.days)
    failed = completed_run(check:, alert_status: "failed", age: 94.days)
    recent = completed_run(alert_status: nil, age: 89.days)

    RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusRun.exists?(without_alert.id)
    assert_not RegistryStatusRun.exists?(sent.id)
    assert RegistryStatusRun.exists?(pending.id)
    assert RegistryStatusRun.exists?(failed.id)
    assert RegistryStatusRun.exists?(recent.id)
    assert_equal [ check.finding_snapshot ], pending.reload.findings
    assert_equal [ check.finding_snapshot ], failed.reload.findings
  end

  private

  def profile_url
    "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
  end

  def member_profile(user, url: profile_url)
    user.create_lawyer_profile!(bar_association: "OVB", bar_number: "cleanup-#{user.id}",
      directory_profile_url: url, directory_name: user.full_name, directory_email: "original@example.test")
  end

  def target_for(profile)
    RegistryStatus::Targets.all.find { |target| target.lawyer_profile_id == profile.id }
  end

  def issue_check(target, outcome: "not_listed", checked_at: @now - 1.day)
    RegistryStatusCheck.create!(source: target.source, target_digest: target.digest,
      identity_digest: target.identity_digest, lawyer_profile_id: target.lawyer_profile_id).tap do |check|
      assert check.record_result!(outcome:, checked_at:, run_on: checked_at.to_date,
        identity_digest: target.identity_digest)
    end
  end

  def legacy_company_check
    digest = RegistryStatusCheck.digest("kbo", "0123456749")
    RegistryStatusCheck.new(source: "kbo", target_digest: digest, identity_digest: digest,
      status: "inactive", issue_status: "inactive", issue_since: @now - 1.day).tap { |check| check.save!(validate: false) }
  end

  def completed_run(check: nil, alert_status:, age: 0.days)
    RegistryStatusRun.create!(run_on: (@now - age).to_date, status: "completed", completed_at: @now - age,
      findings: check ? [ check.finding_snapshot ] : [],
      checked_target_digests: check ? [ check.target_digest ] : [], alert_status:)
  end
end
