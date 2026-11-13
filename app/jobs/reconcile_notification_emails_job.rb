class ReconcileNotificationEmailsJob < ApplicationJob
  MAX_NEW_ASSIGNMENTS_PER_RUN = 100

  queue_as :default

  def perform(now: Time.current)
    Assignment.where(new_assignment_alerts_pending: true).order(:id).limit(MAX_NEW_ASSIGNMENTS_PER_RUN).ids.each do |assignment_id|
      NotifyNewAssignmentJob.perform_later(assignment_id)
    end

    Notification.deliverable_emails(now:).find_each do |notification|
      NotificationEmailDeliveryJob.perform_later(notification.id)
    end
  end
end
