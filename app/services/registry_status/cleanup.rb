module RegistryStatus
  class Cleanup
    RETENTION = 90.days

    def initialize(now: Time.current)
      @now = now
    end

    def call
      legacy_digests = RegistryStatusCheck.where(source: "kbo").pluck(:target_digest).to_set
      protected_ids = RegistryStatusRun.where(alert_status: %w[pending sending failed]).flat_map do |run|
        run.findings.filter_map { |finding| finding["check_id"] }
      end.to_set
      removed = []
      RegistryStatusCheck.find_each do |check|
        check.with_lock do
          # Resolve after locking: registrations and checks can commit while the
          # sweep runs. An older catalog must never delete their new evidence.
          target = Targets.all.find { |candidate| candidate.source == check.source && candidate.digest == check.target_digest }
          if target && target.identity_digest == check.identity_digest &&
              !(check.issue_status.nil? && check.resolved_at && check.resolved_at < @now - RETENTION && !protected_ids.include?(check.id))
            if check.firm_id != target.firm_id || check.lawyer_profile_id != target.lawyer_profile_id
              check.update!(firm_id: target.firm_id, lawyer_profile_id: target.lawyer_profile_id)
            end
            next
          end

          removed << check.id
          check.destroy!
        end
      end
      # Cascading foreign-key deletion can remove a check before this sweep.
      RegistryStatusRun.find_each do |run|
        run.with_lock do
          existing = RegistryStatusCheck.where(id: run.findings.filter_map { |finding| finding["check_id"] }).index_by(&:id)
          relevant_digests = Targets.all.map(&:digest).to_set
          remaining = run.findings.filter_map do |finding|
            check = existing[finding["check_id"]]
            check.sanitize_finding(finding) if check
          end
          digests = run.checked_target_digests.select { |digest| relevant_digests.include?(digest) }
          if remaining != run.findings || digests != run.checked_target_digests
            attributes = { findings: remaining, checked_target_digests: digests }
            if (run.checked_target_digests - digests).any? { |digest| legacy_digests.include?(digest) }
              attributes[:checked_count] = digests.size
            end
            if remaining.empty? && run.alert_status != "sent"
              attributes.merge!(alert_status: nil, alert_claimed_at: nil, alert_retry_at: nil)
            end
            run.update!(attributes)
          end
        end
      end
      RegistryStatusRun.where(status: "completed", alert_status: [ nil, "sent" ]).
        where("completed_at < ?", @now - RETENTION).delete_all
      removed.size
    end
  end
end
