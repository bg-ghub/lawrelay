module Notifications
  class EmailEligibility
    def initialize(notification, recipient: notification.user.reload, now: Time.current)
      @notification, @recipient, @now = notification, recipient, now
    end

    def skip_reason
      return "inactive_recipient" unless @recipient.active?
      return "administrator_recipient" if @recipient.system_admin?
      return "unverified_recipient" if @recipient.email_verification_required?
      return "unverified_marketplace_recipient" unless @recipient.marketplace_verified?
      return "unsupported_event" unless @notification.kind.in?(Notification::EMAIL_KINDS)

      subject = @notification.subject
      return "missing_subject" unless subject

      assignment = subject.is_a?(Proposal) ? subject.assignment : subject
      return "missing_assignment" unless assignment.is_a?(Assignment)
      return "assignment_unavailable" unless assignment.visible_to?(@recipient)

      "superseded_event" unless current_event?(subject, assignment)
    end

    private

    def current_event?(subject, assignment)
      case @notification.kind
      when "new_proposal"
        subject.is_a?(Proposal) && subject.status == "pending" && assignment.status == "open"
      when "proposal_accepted"
        subject.is_a?(Proposal) && subject.status == "accepted" && assignment.status == "matched"
      when "proposal_declined"
        subject.is_a?(Proposal) && subject.status == "declined"
      when "proposal_withdrawn"
        subject.is_a?(Proposal) && subject.status == "withdrawn" && assignment.status == "open"
      when "assignment_matched", "assignment_completed", "assignment_cancelled", "assignment_expired"
        assignment.status == @notification.kind.delete_prefix("assignment_")
      when "response_deadline_closed"
        assignment.status == "open" && assignment.response_deadline_at.present? &&
          assignment.response_deadline_at <= @now && assignment.starts_at > @now
      else
        false
      end
    end
  end
end
