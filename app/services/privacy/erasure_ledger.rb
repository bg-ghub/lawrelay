require "json"
require "pathname"
require "securerandom"
require "time"

module Privacy
  # Kept outside database backups so a restore cannot revive an erased account.
  # It contains only stable database identifiers and timestamps.
  class ErasureLedger
    class UnsafeLedger < StandardError; end

    VERSION = 1
    IDENTITY_KEYS = %w[erased_at user_created_at user_id].freeze
    STAGE_KEYS = (IDENTITY_KEYS + %w[operation_id state version]).sort.freeze
    MARKER_KEYS = %w[operation_id state version].freeze

    def initialize(path: ENV["LAWRELAY_ERASURE_LEDGER"])
      @path = path.to_s
      @lock_path = "#{@path}.lock"
    end

    # This is intentionally durable before the database transaction starts.
    # It cannot be replayed until a separate commit marker is written.
    def stage!(user, erased_at:)
      raise UnsafeLedger, "Administrator accounts cannot enter the erasure ledger" if user.system_admin?

      entry = identity_for(user, erased_at:).merge("version" => VERSION, "operation_id" => SecureRandom.uuid, "state" => "pending")
      with_lock do
        with_file do |file|
          operations = parse(file)
          reject_reused_identity!(operations, entry)
          append!(file, entry)
        end
      end
      entry.fetch("operation_id")
    end

    # Call only after the database transaction committed.
    def commit!(operation_id)
      transition!(operation_id, "committed")
    end

    # Call when the database transaction was not committed. Aborted entries are
    # retained as an audit trail but never replayed.
    def abort!(operation_id)
      transition!(operation_id, "aborted")
    end

    # Returns only reviewed, committed erasures. Pending operations fail closed
    # until reconcile! can prove that their matching account was erased.
    def entries
      with_lock do
        with_file do |file|
          operations = parse(file)
          pending = operations.values.select { |operation| operation.fetch("state") == "pending" }
          raise UnsafeLedger, "Pending erasure ledger operation requires reconciliation" if pending.any?

          operations.values.filter_map do |operation|
            next unless operation.fetch("state") == "committed"

            operation.slice(*IDENTITY_KEYS)
          end
        end
      end
    end

    # On a restored database, complete only a staged operation whose exact
    # account is already marked erased. An active, missing or changed account is
    # ambiguous and deliberately stops startup/recovery for operator review.
    def reconcile!
      with_lock do
        with_file do |file|
          operations = parse(file)
          operations.values.select { |operation| operation.fetch("state") == "pending" }.each do |operation|
            user = User.find_by(id: operation.fetch("user_id"))
            matches = user && !user.system_admin? && user.erased_at &&
              timestamp(user.created_at) == operation.fetch("user_created_at") &&
              timestamp(user.erased_at) == operation.fetch("erased_at")
            raise UnsafeLedger, "Pending erasure ledger operation needs operator review" unless matches

            append!(file, marker(operation.fetch("operation_id"), "committed"))
          end
        end
      end
      true
    end

    # Completed ledger records are retained for two years. Pending records are
    # never removed: they require operator reconciliation, not expiration.
    def prune!(before: 2.years.ago)
      cutoff = timestamp(before)
      with_lock do
        with_file do |file|
          operations = parse(file)
          retained = operations.values.reject do |operation|
            operation.fetch("state").in?(%w[committed aborted]) && operation.fetch("erased_at") < cutoff
          end
          rewrite!(retained) if retained.length != operations.length
        end
      end
      true
    end

    private

    def transition!(operation_id, state)
      raise UnsafeLedger, "Invalid erasure ledger operation" unless operation_id.to_s.match?(uuid_pattern)

      with_lock do
        with_file do |file|
          operations = parse(file)
          operation = operations.fetch(operation_id) { raise UnsafeLedger, "Unknown erasure ledger operation" }
          raise UnsafeLedger, "Erasure ledger operation is already final" unless operation.fetch("state") == "pending"

          append!(file, marker(operation_id, state))
        end
      end
      true
    end

    def identity_for(user, erased_at:)
      raise UnsafeLedger, "Invalid erasure ledger user" unless user.id.is_a?(Integer) && user.id.positive? && user.created_at

      { "user_id" => user.id, "user_created_at" => timestamp(user.created_at), "erased_at" => timestamp(erased_at) }
    end

    def marker(operation_id, state)
      { "version" => VERSION, "operation_id" => operation_id, "state" => state }
    end

    def timestamp(value)
      value.utc.iso8601(6)
    end

    def uuid_pattern
      /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    end

    def reject_reused_identity!(operations, entry)
      same_account = operations.values.any? do |operation|
        operation.values_at("user_id", "user_created_at") == entry.values_at("user_id", "user_created_at") &&
          operation.fetch("state") != "aborted"
      end
      raise UnsafeLedger, "Account already has an erasure ledger operation" if same_account
    end

    def parse(file)
      file.rewind
      operations = {}
      file.each_line do |line|
        value = JSON.parse(line)
        validate_hash!(value)
        operation_id = value.fetch("operation_id")
        if value.keys.sort == STAGE_KEYS
          raise UnsafeLedger, "Duplicate erasure ledger operation" if operations.key?(operation_id)
          operations[operation_id] = value
        elsif value.keys.sort == MARKER_KEYS
          operation = operations.fetch(operation_id) { raise UnsafeLedger, "Erasure ledger marker has no staged operation" }
          raise UnsafeLedger, "Erasure ledger operation has conflicting final state" unless operation.fetch("state") == "pending"
          operation["state"] = value.fetch("state")
        else
          raise UnsafeLedger, "Invalid erasure ledger entry"
        end
      end
      operations
    rescue JSON::ParserError, ArgumentError, KeyError
      raise UnsafeLedger, "Invalid erasure ledger entry", cause: nil
    end

    def validate_hash!(value)
      raise UnsafeLedger, "Invalid erasure ledger entry" unless value.is_a?(Hash) && value.fetch("version") == VERSION
      operation_id = value.fetch("operation_id")
      raise UnsafeLedger, "Invalid erasure ledger operation" unless operation_id.is_a?(String) && operation_id.match?(uuid_pattern)

      state = value.fetch("state")
      if value.keys.sort == STAGE_KEYS
        raise UnsafeLedger, "Invalid erasure ledger stage" unless state == "pending" && value.fetch("user_id").is_a?(Integer) && value.fetch("user_id").positive?
        Time.iso8601(value.fetch("user_created_at"))
        Time.iso8601(value.fetch("erased_at"))
      elsif value.keys.sort == MARKER_KEYS
        raise UnsafeLedger, "Invalid erasure ledger marker" unless state.in?(%w[committed aborted])
      else
        raise UnsafeLedger, "Invalid erasure ledger entry"
      end
    end

    def append!(file, entry)
      file.seek(0, IO::SEEK_END)
      file.write(JSON.generate(entry) + "\n")
      file.flush
      file.fsync
    end

    def with_lock
      raise UnsafeLedger, "Configure a protected erasure ledger outside the application" if @path.blank? || Gem.win_platform?
      directory = File.dirname(@path)
      raise UnsafeLedger, "Use a canonical absolute ledger path" unless Pathname.new(@path).absolute? && File.realpath(directory) == directory
      raise UnsafeLedger, "Keep the erasure ledger outside application storage" if directory == Rails.root.to_s || directory.start_with?(Rails.root.to_s + File::SEPARATOR)
      parent = File.stat(directory)
      raise UnsafeLedger, "Erasure ledger directory must be owned and mode 0700" unless parent.uid == Process.uid && (parent.mode & 0o777) == 0o700

      with_private_file(@lock_path) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      ensure
        lock&.flock(File::LOCK_UN)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP, Errno::ENOTDIR
      raise UnsafeLedger, "Erasure ledger path is unavailable or unsafe", cause: nil
    end

    def with_file
      with_private_file(@path) { |file| yield file }
    end

    def with_private_file(path)
      flags = File::RDWR | File::CREAT | File::NOFOLLOW
      File.open(path, flags, 0o600) do |file|
        stat = file.stat
        raise UnsafeLedger, "Erasure ledger must be a private owned regular file" unless stat.file? && stat.uid == Process.uid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1
        yield file
      end
    end

    def rewrite!(operations)
      directory = File.dirname(@path)
      temporary_path = File.join(directory, ".#{File.basename(@path)}.#{SecureRandom.hex(16)}.tmp")
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |temporary|
        operations.each do |operation|
          stage = operation.slice(*STAGE_KEYS).merge("state" => "pending")
          temporary.write(JSON.generate(stage) + "\n")
          temporary.write(JSON.generate(marker(operation.fetch("operation_id"), operation.fetch("state"))) + "\n") unless operation.fetch("state") == "pending"
        end
        temporary.flush
        temporary.fsync
      end
      File.rename(temporary_path, @path)
      File.open(directory, File::RDONLY) { |directory_file| directory_file.fsync }
    ensure
      File.unlink(temporary_path) if temporary_path && File.exist?(temporary_path)
    end
  end
end
