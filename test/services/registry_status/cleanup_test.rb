require "test_helper"

class RegistryStatus::CleanupTest < ActiveSupport::TestCase
  setup do
    @now = Time.utc(2026, 10, 31, 12)
  end

  test "erasure removes monitoring state and cancels an unsent empty alert" do
    firm = member_firm(users(:one))
    check = issue_check(target_for(firm))
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

  test "changed enterprise numbers remove the old digest and scrub its run snapshot" do
    firm = member_firm(users(:one))
    check = issue_check(target_for(firm))
    run = completed_run(check:, alert_status: "sent")
    firm.update!(enterprise_number: "1234567894")

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_equal "sent", run.alert_status
  end

  test "changed directory comparison identity removes old monitoring evidence" do
    profile = member_profile(users(:one))
    target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == profile.id }
    check = issue_check(target, outcome: "changed")
    run = completed_run(check:, alert_status: "pending")
    profile.update!(directory_email: "replacement@example.test")

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_nil run.alert_status
  end

  test "deleting the last representative target also scrubs persisted run references" do
    firm = member_firm(users(:one))
    check = issue_check(target_for(firm))
    run = completed_run(check:, alert_status: "pending")
    firm.destroy!
    assert_nil check.reload.firm_id

    RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(check.id)
    assert_empty run.reload.findings
    assert_empty run.checked_target_digests
    assert_nil run.alert_status
  end

  test "a duplicate enterprise number retains its issue when the representative firm loses its last member" do
    original_firm = member_firm(users(:one))
    replacement_firm = member_firm(users(:two), enterprise_number: "BE 0123.456.749")
    check = issue_check(target_for(original_firm))
    run = completed_run(check:, alert_status: "pending")
    issue_since = check.issue_since
    original_firm.memberships.destroy_all

    assert_equal 0, RegistryStatus::Cleanup.new(now: @now).call

    assert_equal replacement_firm.id, check.reload.firm_id
    assert_equal "inactive", check.issue_status
    assert_equal issue_since, check.issue_since
    assert_equal "inactive", check.last_definitive_status
    assert_equal replacement_firm.id, run.reload.findings.sole.fetch("firm_id")
    assert_equal [ check.target_digest ], run.checked_target_digests
    assert_equal "pending", run.alert_status
  end

  test "resolved check metadata expires after ninety days while an unresolved issue remains" do
    resolved_firm = member_firm(users(:one))
    unresolved_firm = member_firm(users(:two), enterprise_number: "1234567894")
    resolved = issue_check(target_for(resolved_firm), checked_at: @now - 100.days)
    resolved.record_result!(outcome: "ok", checked_at: @now - 91.days,
      run_on: (@now - 91.days).to_date, identity_digest: resolved.identity_digest)
    unresolved = issue_check(target_for(unresolved_firm), checked_at: @now - 100.days)

    assert_equal 1, RegistryStatus::Cleanup.new(now: @now).call

    assert_not RegistryStatusCheck.exists?(resolved.id)
    assert RegistryStatusCheck.exists?(unresolved.id)
    assert_equal "inactive", unresolved.reload.issue_status
  end

  test "deleting a shared number representative preserves dedup state for the remaining member" do
    original = member_firm(users(:one))
    replacement = member_firm(users(:two))
    check = issue_check(target_for(original))
    run = completed_run(check:, alert_status: "pending")
    original.destroy!
    assert_nil check.reload.firm_id

    RegistryStatus::Cleanup.new(now: @now).call

    assert_equal replacement.id, check.reload.firm_id
    assert_equal "inactive", check.issue_status
    assert_equal "inactive", check.last_definitive_status
    assert_equal replacement.id, run.reload.findings.sole.fetch("firm_id")
    assert_not check.record_result!(outcome: "inactive", checked_at: @now, run_on: @now.to_date,
      identity_digest: check.identity_digest)
  end

  test "a finding committed before a run lock is not removed using an earlier check snapshot" do
    firm = member_firm(users(:one))
    run = completed_run(alert_status: nil)
    injected_check = nil
    inject = -> do
      injected_check = issue_check(target_for(firm))
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
    target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == profile.id }
    check = issue_check(target, outcome: "changed")
    inject = -> do
      profile.update!(directory_email: "updated-before-lock@example.test")
      current = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == profile.id }
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

  test "old completed run metadata expires while pending and failed alert snapshots remain recoverable" do
    firm = member_firm(users(:one))
    check = issue_check(target_for(firm))
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

  def member_firm(user, enterprise_number: "0123456749")
    Firm.create!(name: "Monitoring cleanup example", enterprise_number:).tap do |firm|
      user.memberships.create!(firm:, role: "member")
    end
  end

  def member_profile(user)
    user.create_lawyer_profile!(bar_association: "OVB", bar_number: "cleanup-#{user.id}",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/12345678-1234-1234-1234-123456789abc",
      directory_name: user.full_name, directory_email: "original@example.test")
  end

  def target_for(firm)
    RegistryStatus::Targets.all.find { |target| target.firm_id == firm.id }
  end

  def issue_check(target, outcome: "inactive", checked_at: @now - 1.day)
    RegistryStatusCheck.create!(source: target.source, target_digest: target.digest,
      identity_digest: target.identity_digest, firm_id: target.firm_id, lawyer_profile_id: target.lawyer_profile_id).tap do |check|
      assert check.record_result!(outcome:, checked_at:, run_on: checked_at.to_date,
        identity_digest: target.identity_digest)
    end
  end

  def completed_run(check: nil, alert_status:, age: 0.days)
    RegistryStatusRun.create!(run_on: (@now - age).to_date, status: "completed", completed_at: @now - age,
      findings: check ? [ check.finding_snapshot ] : [],
      checked_target_digests: check ? [ check.target_digest ] : [], alert_status:)
  end
end
