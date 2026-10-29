module Retention
  module Protection
    module_function

    ACTIVE_ASSIGNMENT_STATUSES = %w[draft open matched].freeze
    TERMINAL_REPORT_STATUSES = %w[resolved dismissed].freeze
    TERMINAL_PRIVACY_REQUEST_STATUSES = %w[completed rejected].freeze

    # Holds only travel across data that would otherwise be removed together.
    # An unrelated hold elsewhere in the marketplace must not stop cleanup.
    def held?(record, now: Time.current, ignored_privacy_request_id: nil)
      return false unless record
      return true if explicit_hold?(record, now:)

      case record
      when User
        user_held?(record, now:, ignored_privacy_request_id:)
      when Assignment
        assignment_held?(record, now:, ignored_privacy_request_id:)
      when Proposal
        assignment_held?(record.assignment, now:, ignored_privacy_request_id:) ||
          (record.user && user_directly_held?(record.user, now:, ignored_privacy_request_id:))
      when Firm
        firm_held?(record, now:, ignored_privacy_request_id:)
      when Report
        !record.status.in?(TERMINAL_REPORT_STATUSES)
      when PrivacyRequest
        !record.status.in?(TERMINAL_PRIVACY_REQUEST_STATUSES)
      else
        false
      end
    end

    def explicit_hold?(record, now: Time.current)
      RetentionHold.active(now:).where(subject: record).exists?
    end

    def user_held?(user, now:, ignored_privacy_request_id:)
      return true if user_directly_held?(user, now:, ignored_privacy_request_id:)
      return true if user.created_assignments.where(status: ACTIVE_ASSIGNMENT_STATUSES).exists?
      return true if user.proposals.joins(:assignment).where(assignments: { status: ACTIVE_ASSIGNMENT_STATUSES }).exists?
      return true if assignment_hold_for?(user.created_assignments, now:)

      assignment_hold_for?(Assignment.joins(:proposals).where(proposals: { user_id: user.id }), now:)
    end

    # This deliberately does not recurse into the firm's other users. It is
    # used from assignment/proposal paths and keeps protection local.
    def user_directly_held?(user, now:, ignored_privacy_request_id:)
      return true if explicit_hold?(user, now:)

      requests = user.privacy_requests.where.not(status: TERMINAL_PRIVACY_REQUEST_STATUSES)
      requests = requests.where.not(id: ignored_privacy_request_id) if ignored_privacy_request_id
      return true if requests.exists?
      return true if user.submitted_reports.where.not(status: TERMINAL_REPORT_STATUSES).exists?
      return true if user.firms.any? { |firm| explicit_hold?(firm, now:) }
      return true if user.privacy_requests.any? { |request| explicit_hold?(request, now:) }

      user.submitted_reports.any? { |report| explicit_hold?(report, now:) }
    end

    def assignment_held?(assignment, now:, ignored_privacy_request_id:)
      return true if assignment.status.in?(ACTIVE_ASSIGNMENT_STATUSES)
      return true if assignment.starts_at.present? && assignment.starts_at >= now
      return true if assignment.firm && explicit_hold?(assignment.firm, now:)
      return true if assignment.creator_user && user_directly_held?(assignment.creator_user, now:, ignored_privacy_request_id:)

      reports = Report.where(reportable: assignment)
      return true if reports.where.not(status: TERMINAL_REPORT_STATUSES).exists?
      return true if reports.any? { |report| explicit_hold?(report, now:) }

      assignment.proposals.any? do |proposal|
        proposal.user && user_directly_held?(proposal.user, now:, ignored_privacy_request_id:)
      end
    end

    def firm_held?(firm, now:, ignored_privacy_request_id:)
      return true if explicit_hold?(firm, now:)
      return true if firm.assignments.where(status: ACTIVE_ASSIGNMENT_STATUSES).exists?
      return true if assignment_hold_for?(firm.assignments, now:)

      firm.users.any? { |user| user_directly_held?(user, now:, ignored_privacy_request_id:) }
    end

    def assignment_hold_for?(assignments, now:)
      RetentionHold.active(now:).where(subject_type: "Assignment", subject_id: assignments.select(:id)).exists?
    end
  end
end
