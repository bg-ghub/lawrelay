module RegistryStatus
  class Checker
    MAX_CHECKS_PER_EXECUTION = 50
    REQUEST_INTERVAL = 1.second

    def initialize(run:, token:, sleeper: ->(duration) { Kernel.sleep(duration) })
      @run = run
      @token = token
      @sleeper = sleeper
    end

    def call
      completed = @run.checked_target_digests.to_set
      targets = Targets.all.reject { |target| completed.include?(target.digest) }
      targets.first(MAX_CHECKS_PER_EXECUTION).each_with_index do |target, index|
        return :lost_lease unless @run.current_lease?(@token)

        @sleeper.call(REQUEST_INTERVAL) if index.positive?
        result = lookup(target)
        return :lost_lease unless persist_result(target, result)
      end

      if targets.size > MAX_CHECKS_PER_EXECUTION
        @run.release!(@token)
        :continue
      else
        @run.complete!(@token) ? :completed : :lost_lease
      end
    end

    private

    def lookup(target)
      Directory::StatusCheck.call(profile_url: target.value, full_name: target.full_name, expected_email: target.expected_email)
    end

    def persist_result(target, result)
      @run.with_lock do
        return false unless @run.lease_token == @token && @run.status == "running"
        return true if @run.checked_target_digests.include?(target.digest)

        now = Time.current
        findings = @run.findings.dup
        # A member may have erased or changed these details during the request.
        current = Targets.all.find { |candidate| candidate.digest == target.digest && candidate.identity_digest == target.identity_digest }
        if current
          check = RegistryStatusCheck.find_or_initialize_by(source: current.source, target_digest: current.digest)
          check.assign_attributes(firm_id: current.firm_id, lawyer_profile_id: current.lawyer_profile_id)
          new_issue = check.record_result!(outcome: result.status, checked_at: now,
            run_on: @run.run_on, identity_digest: current.identity_digest)
          findings << check.finding_snapshot if new_issue
        end
        @run.update!(findings:, checked_count: @run.checked_count + 1,
          checked_target_digests: @run.checked_target_digests + [ target.digest ], lease_expires_at: now + RegistryStatusRun::RUN_LEASE)
        true
      end
    end
  end
end
