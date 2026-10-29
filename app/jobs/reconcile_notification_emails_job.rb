class ReconcileNotificationEmailsJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    Notification.deliverable_emails(now:).find_each do |notification|
      NotificationEmailDeliveryJob.perform_later(notification.id)
    end
  end
end
