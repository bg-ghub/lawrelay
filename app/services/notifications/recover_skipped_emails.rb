module Notifications
  class RecoverSkippedEmails
    MAX_AGE = 24.hours
    ACTION_EVENTS = %w[new_proposal proposal_accepted proposal_declined proposal_withdrawn assignment_matched response_deadline_closed].freeze
    Result = Data.define(:dry_run, :notification_ids)

    def initialize(dry_run: true, now: Time.current)
      @dry_run, @now = dry_run, now
    end

    # Explicit repair only: do not replay old or superseded notifications daily.
    # Restored pending events use the normal durable outbox reconciler.
    def call
      ids = []
      scope.find_each do |notification|
        notification.with_lock do
          next unless recoverable?(notification)

          ids << notification.id
          next if @dry_run

          notification.update!(email_status: "pending", email_status_reason: nil, email_attempts: 0,
            email_retry_at: nil, email_claimed_at: nil)
          AuditEvent.create!(auditable: notification, action: "notification.email_recovered",
            metadata: { source: "rake", previous_reason: "unverified_recipient" })
        end
      end
      Result.new(dry_run: @dry_run, notification_ids: ids)
    end

    private

    def scope
      Notification.email_outbox.where(email_status: "skipped", email_status_reason: "unverified_recipient", email_sent_at: nil)
        .where(created_at: (@now - MAX_AGE)..@now)
    end

    def recoverable?(notification)
      return false unless scope.exists?(id: notification.id)
      return false if Notifications::EmailEligibility.new(notification, now: @now).skip_reason
      return true unless notification.kind.in?(ACTION_EVENTS)

      subject = notification.subject
      assignment = subject.is_a?(Proposal) ? subject.assignment : subject
      return false unless assignment.starts_at > @now
      return false if notification.kind == "new_proposal" && !assignment.accepting_proposals?(now: @now)
      return false if notification.kind == "proposal_declined" && !assignment.status.in?(%w[open matched])

      true
    end
  end
end
