module Privacy
  class ErasureInventory
    def initialize(request:, actor:)
      @request = request
      @actor = actor
      @context = RequestContext.new(request:, actor:, kind: "deletion")
    end

    def call(output_path:)
      file = PrivateJsonFile.new(output_path)
      PrivacyRequest.transaction do
        @request.lock!
        @context.validate!
        file.write!(package)
        AuditEvent.create!(auditable: @request, actor_user: @actor, action: "privacy.erasure_inventory_prepared",
          metadata: { source: "rake", format_version: 1 })
      end
      true
    rescue StandardError
      file.remove_created!
      raise
    end

    private

    def package
      user = @context.user
      {
        format_version: 1, prepared_at: Time.current.iso8601, request_id: @request.id,
        dry_run: true, deletion_performed: false, hold_decision: "not_assessed", automatic_deletion_allowed: false,
        account_id: user.id,
        references: {
          memberships: user.memberships.count,
          shared_firms: Membership.where(firm_id: user.firm_ids).where.not(user_id: user.id).distinct.count(:firm_id),
          created_assignments: user.created_assignments.count,
          proposals: user.proposals.count,
          notifications: user.notifications.count,
          professional_status_checks: user.lawyer_profile ? RegistryStatusCheck.where(lawyer_profile: user.lawyer_profile).count : 0,
          sessions: user.sessions.count,
          privacy_requests: user.privacy_requests.count,
          submitted_reports: user.submitted_reports.count,
          handled_privacy_requests: PrivacyRequest.where(handled_by_user_id: user.id).count,
          reviewed_reports: Report.where(reviewed_by_user_id: user.id).count,
          acted_audit_events: AuditEvent.where(actor_user_id: user.id).count,
          account_audit_events: AuditEvent.where(auditable: user).count
        },
        review_required: [
          "Check identity, scope, applicable retention, legal holds and obligations to other participants before deciding.",
          "Map indirect profile/assignment/proposal/report/firm audit references, billing records and other participants' authored text separately.",
          "Review support mail, logs, provider records and backups; record approved deletion restrictions and reapply after restoration.",
          "This inventory changes no account data and does not assess holds, authorize deletion or complete the privacy request."
        ]
      }
    end
  end
end
