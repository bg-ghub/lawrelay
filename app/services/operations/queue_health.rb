module Operations
  class QueueHealth
    MAX_WAIT = 15.minutes

    def self.healthy?(now: Time.current)
      cutoff = now - MAX_WAIT

      !SolidQueue::FailedExecution.exists? &&
        !SolidQueue::ReadyExecution.where("created_at < ?", cutoff).exists? &&
        !SolidQueue::ScheduledExecution.where("scheduled_at < ?", cutoff).exists? &&
        !Notification.email_delivery_unhealthy?(now:) &&
        !RegistryStatusRun.alert_delivery_unhealthy?(now:)
    rescue ActiveRecord::ActiveRecordError => error
      Rails.logger.error("Operational queue health check failed: #{error.class}")
      false
    end
  end
end
