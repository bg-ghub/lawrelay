require "test_helper"
require "tmpdir"

class PrivacyErasureLedgerTest < ActiveSupport::TestCase
  setup do
    @directory = Dir.mktmpdir("lawrelay-erasure-ledger-")
    File.chmod(0o700, @directory)
    @path = File.join(@directory, "erasures.jsonl")
    @ledger = Privacy::ErasureLedger.new(path: @path)
  end

  teardown { FileUtils.remove_entry_secure(@directory) if File.directory?(@directory) }

  test "only a committed staged operation is replayable and it stores no contact data" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    user = users(:one)
    operation = @ledger.stage!(user, erased_at: Time.current)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    assert @ledger.commit!(operation)
    assert_equal [ user.id ], @ledger.entries.pluck("user_id")
    assert_equal 0o600, File.stat(@path).mode & 0o777
    raw = File.read(@path)
    assert_not_includes raw, user.email_address
    assert_not_includes raw, user.password_digest
    assert_includes raw, '"state":"pending"'
    assert_includes raw, '"state":"committed"'
  end

  test "aborted operations are never replayed and may be safely retried" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    user = users(:one)
    operation = @ledger.stage!(user, erased_at: Time.current)
    assert @ledger.abort!(operation)
    assert_empty @ledger.entries
    retry_operation = @ledger.stage!(user, erased_at: Time.current)
    assert_not_equal operation, retry_operation
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.commit!(operation) }
  end

  test "prune removes only completed records older than the cutoff" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    old_operation = @ledger.stage!(users(:one), erased_at: 3.years.ago)
    @ledger.commit!(old_operation)
    old_aborted_operation = @ledger.stage!(users(:two), erased_at: 3.years.ago)
    @ledger.abort!(old_aborted_operation)
    recent_operation = @ledger.stage!(users(:two), erased_at: 1.year.ago)
    @ledger.commit!(recent_operation)

    assert @ledger.prune!(before: 2.years.ago)
    assert_equal [ users(:two).id ], @ledger.entries.pluck("user_id")
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.commit!(old_operation) }
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.commit!(old_aborted_operation) }
  end

  test "prune preserves pending operations even when their timestamps are old" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    @ledger.stage!(users(:one), erased_at: 3.years.ago)

    assert @ledger.prune!(before: 2.years.ago)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
  end

  test "markers, malformed state and pending operations fail closed" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    File.write(@path, %({"version":1,"operation_id":"0c1b5bc3-9b81-4cfb-9d3d-123456789abc","state":"committed"}\n))
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    File.write(@path, "invalid-json\n")
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
  end

  test "reconcile commits only an exactly matching erased member" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    user = users(:one)
    erased_at = Time.current.change(usec: 0)
    operation = @ledger.stage!(user, erased_at:)
    user.update_columns(erased_at:)
    assert @ledger.reconcile!
    assert_equal [ user.id ], @ledger.entries.pluck("user_id")
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.commit!(operation) }
  end

  test "reconcile refuses an active account" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    @ledger.stage!(users(:one), erased_at: Time.current)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.reconcile! }
  end

  test "unsafe modes, links, missing paths and Windows are refused" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    @ledger.entries
    File.chmod(0o644, @path)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    File.chmod(0o600, @path)
    File.unlink(@path)
    File.symlink(File.join(@directory, "target"), @path)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    File.unlink(@path)
    File.chmod(0o755, @directory)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { Privacy::ErasureLedger.new(path: "relative").entries }
  end

  test "the separate lock file is also private and cannot be a link" do
    skip "Requires POSIX permissions" if Gem.win_platform?
    @ledger.entries
    lock_path = "#{@path}.lock"
    File.chmod(0o644, lock_path)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
    File.unlink(lock_path)
    File.symlink(File.join(@directory, "lock-target"), lock_path)
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
  end

  test "Windows refuses a ledger it cannot protect with POSIX modes" do
    skip "Windows-specific refusal" unless Gem.win_platform?
    assert_raises(Privacy::ErasureLedger::UnsafeLedger) { @ledger.entries }
  end
end
