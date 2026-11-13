class NotifyNewAssignmentJob < ApplicationJob
  queue_as :default
  retry_on ActiveRecord::StatementInvalid, wait: 1.minute, attempts: 3

  def perform(assignment_id)
    assignment = Assignment.find_by(id: assignment_id, new_assignment_alerts_pending: true)
    return unless assignment

    publish_alerts(assignment) if assignment.accepting_proposals? && assignment.firm_id && assignment.creator_user_id
    assignment.update_columns(new_assignment_alerts_pending: false)
  end

  private

  def publish_alerts(assignment)
    recipients(assignment).find_each(batch_size: 100) do |recipient|
      next unless recipient.marketplace_verified?

      Notification.publish!(user: recipient, kind: "new_assignment", subject: assignment, assignment:)
    end
  end

  def recipients(assignment)
    User.where(system_role: "member", new_assignment_alerts: true, suspended_at: nil, erased_at: nil)
      .where.not(id: assignment.creator_user_id)
      .where.not(id: Membership.where(firm_id: assignment.firm_id).select(:user_id))
      .includes(:lawyer_profile)
  end
end
