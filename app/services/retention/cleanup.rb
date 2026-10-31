module Retention
  class Cleanup
    Result = Data.define(:unverified_users, :assignments, :notifications, :reports, :privacy_requests, :audit_events, :erased_users, :retention_holds) do
      def to_h = members.zip(deconstruct).to_h
    end

    def initialize(now: Time.current, dry_run: true)
      @now = now
      @dry_run = dry_run
      @counts = Hash.new(0)
    end

    def call
      purge_unverified_users
      purge_assignments
      purge_notifications
      purge_terminal_records(Report, :reports)
      purge_terminal_records(PrivacyRequest, :privacy_requests)
      purge_audit_events
      purge_erased_users
      purge_expired_holds
      Result.new(**Result.members.index_with { |key| @counts[key] })
    end

    private

    def purge_unverified_users
      User.where(system_role: "member", email_verified_at: nil, erased_at: nil).where(updated_at: ..Policy.before(Policy::UNVERIFIED_REGISTRATION, now: @now)).find_each do |user|
        next unless stale_unverified?(user)

        destroy(user, :unverified_users) do
          user.lock!
          next unless stale_unverified?(user)

          remove_isolated_registration!(user)
        end
      end
    end

    def stale_unverified?(user)
      cutoff = Policy.before(Policy::UNVERIFIED_REGISTRATION, now: @now)
      return false unless user.system_role == "member" && user.email_verified_at.nil? && user.erased_at.nil?
      return false unless user.updated_at <= cutoff
      profile = user.lawyer_profile
      return false if profile&.manual_activation_valid?
      return false if Protection.held?(user, now: @now)
      return false if user.created_assignments.exists? || user.proposals.exists? || user.privacy_requests.exists? || user.submitted_reports.exists?
      return false unless isolated_registration?(user)

      return false if profile && profile.updated_at > cutoff
      return false if profile&.verified_at || user.firms.where.not(verified_at: nil).exists?

      last_seen = user.sessions.maximum(:last_seen_at)
      last_seen.blank? || last_seen <= cutoff
    end

    def isolated_registration?(user)
      memberships = user.memberships.includes(:firm).to_a
      return false unless memberships.one?

      firm = memberships.first.firm
      return false unless firm.users.where.not(id: user.id).none?
      return false if firm.assignments.exists? || Proposal.where(firm: firm).exists?

      account = firm.billing_account
      return false if account && (!account.subscriptions.empty? || !account.billing_payments.empty? || !account.invoices.empty? || account.provider_customer_id.present?)

      registration_audits(user:, firm:, account:).all? { |event| event.actor_user_id.blank? || event.actor_user_id == user.id }
    end

    def registration_audits(user:, firm:, account:)
      records = [ user, user.lawyer_profile, firm, account ].compact
      records.reduce(AuditEvent.where(actor_user: user).or(AuditEvent.where(firm: firm))) do |scope, record|
        scope.or(AuditEvent.where(auditable: record))
      end
    end

    def remove_isolated_registration!(user)
      firm = user.primary_firm
      account = firm&.billing_account
      registration_audits(user:, firm:, account:).destroy_all
      account&.destroy!
      user.destroy!
      firm.destroy! if firm && firm.users.reload.none?
    end

    def purge_assignments
      Assignment.where(status: %w[completed cancelled expired]).where(closed_at: ..Policy.before(Policy::CLOSED_WORK, now: @now)).find_each do |assignment|
        next unless removable_assignment?(assignment)

        destroy(assignment, :assignments) do
          assignment.lock!
          next unless removable_assignment?(assignment)

          related_notifications(assignment).find_each do |notification|
            notification.lock!
            raise ActiveRecord::RecordInvalid, notification unless removable_notification?(notification)
            notification.destroy!
          end
          assignment.destroy!
        end
      end
    end

    def removable_assignment?(assignment)
      return false unless assignment.status.in?(%w[completed cancelled expired]) && assignment.closed_at && assignment.closed_at <= Policy.before(Policy::CLOSED_WORK, now: @now)
      return false if Protection.held?(assignment, now: @now)

      # Keep reported work intact until the report itself has been removed.
      return false if Report.where(reportable: assignment).exists?

      related_notifications(assignment).all? { |notification| removable_notification?(notification) }
    end

    def purge_notifications
      terminal_statuses = [ nil, "sent", "skipped" ]
      Notification.where(created_at: ..Policy.before(Policy::NOTIFICATION, now: @now)).where(email_status: terminal_statuses).find_each do |notification|
        next unless removable_notification?(notification)

        destroy(notification, :notifications) do
          notification.lock!
          notification.destroy! if removable_notification?(notification)
        end
      end
    end

    def removable_notification?(notification)
      return false unless notification.created_at <= Policy.before(Policy::NOTIFICATION, now: @now)
      return false unless notification.email_status.in?([ nil, "sent", "skipped" ])
      return false if notification.subject && Protection.held?(notification.subject, now: @now)

      assignment = notification_assignment(notification)
      !assignment || !Protection.held?(assignment, now: @now)
    end

    def related_notifications(assignment)
      proposal_ids = assignment.proposals.select(:id)
      direct = Notification.where(subject: assignment)
      proposal = Notification.where(subject_type: "Proposal", subject_id: proposal_ids)
      by_data = Notification.where("json_extract(data, '$.assignment_id') = ?", assignment.id)
      direct.or(proposal).or(by_data).distinct
    end

    def notification_assignment(notification)
      subject_assignment = case notification.subject
      when Assignment then notification.subject
      when Proposal then notification.subject.assignment
      end
      return subject_assignment if subject_assignment

      assignment_id = notification.data&.fetch("assignment_id", nil) || notification.data&.fetch(:assignment_id, nil)
      Assignment.find_by(id: assignment_id) if assignment_id
    end

    def purge_terminal_records(model, key)
      model.where(status: model == Report ? %w[resolved dismissed] : %w[completed rejected])
        .where(resolved_at: ..Policy.before(Policy::RESOLVED_REQUEST, now: @now)).find_each do |record|
        next unless removable_terminal_record?(record, model)

        destroy(record, key) do
          record.lock!
          record.destroy! if removable_terminal_record?(record, model)
        end
      end
    end

    def removable_terminal_record?(record, model)
      terminal_statuses = model == Report ? %w[resolved dismissed] : %w[completed rejected]
      return false unless record.status.in?(terminal_statuses) && record.resolved_at &&
        record.resolved_at <= Policy.before(Policy::RESOLVED_REQUEST, now: @now)
      return false if Protection.held?(record, now: @now)

      case record
      when Report
        !Protection.held?(record.reportable, now: @now) && !Protection.held?(record.reporter_user, now: @now)
      when PrivacyRequest
        !Protection.held?(record.user, now: @now)
      end
    end

    def purge_audit_events
      AuditEvent.where(created_at: ..Policy.before(Policy::AUDIT_EVENT, now: @now)).find_each do |event|
        next if event.auditable && Protection.held?(event.auditable, now: @now)
        next if event.actor_user && Protection.held?(event.actor_user, now: @now)
        next if event.firm && Protection.held?(event.firm, now: @now)

        destroy(event, :audit_events) do
          event.lock!
          event.destroy! if removable_audit_event?(event)
        end
      end
    end

    def removable_audit_event?(event)
      return false unless event.created_at <= Policy.before(Policy::AUDIT_EVENT, now: @now)
      return false if event.auditable && Protection.held?(event.auditable, now: @now)
      return false if event.firm && Protection.held?(event.firm, now: @now)

      !event.actor_user || !Protection.held?(event.actor_user, now: @now)
    end

    def purge_erased_users
      User.where(system_role: "member").where.not(erased_at: nil).where(erased_at: ..Policy.before(Policy::ERASED_ACCOUNT, now: @now)).find_each do |user|
        next if Protection.held?(user, now: @now)
        next if user.created_assignments.exists? || user.proposals.exists? || user.privacy_requests.exists? || user.submitted_reports.exists?
        next if AuditEvent.where(actor_user: user).or(AuditEvent.where(auditable: user)).exists?

        destroy(user, :erased_users) do
          user.lock!
          user.destroy! if removable_erased_user?(user)
        end
      end
    end

    def removable_erased_user?(user)
      user.system_role == "member" && user.erased_at &&
        user.erased_at <= Policy.before(Policy::ERASED_ACCOUNT, now: @now) &&
        !Protection.held?(user, now: @now) &&
        !user.created_assignments.exists? && !user.proposals.exists? &&
        !user.privacy_requests.exists? && !user.submitted_reports.exists? &&
        !AuditEvent.where(actor_user: user).or(AuditEvent.where(auditable: user)).exists?
    end

    def purge_expired_holds
      RetentionHold.where(expires_at: ..Policy.before(Policy::AUDIT_EVENT, now: @now)).find_each do |hold|
        next if Protection.held?(hold.subject, now: @now)

        destroy(hold, :retention_holds) do
          hold.lock!
          hold.destroy! if hold.expires_at <= Policy.before(Policy::AUDIT_EVENT, now: @now) &&
            !Protection.held?(hold.subject, now: @now)
        end
      end
    end

    def destroy(record, key)
      if @dry_run
        @counts[key] += 1
      else
        ApplicationRecord.transaction { yield }
        @counts[key] += 1 unless record.persisted?
      end
    end
  end
end
