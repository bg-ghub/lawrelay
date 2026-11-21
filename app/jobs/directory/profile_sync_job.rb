module Directory
  class ProfileSyncJob < ApplicationJob
    class TemporarilyUnavailable < StandardError; end

    queue_as :default
    limits_concurrency to: 1, key: "directory-profile-sync-provider", duration: 1.minute
    retry_on TemporarilyUnavailable, wait: 5.minutes, attempts: 3
    after_discard do |_job, error|
      log_outcome(:failed, error.is_a?(TemporarilyUnavailable) ? :unavailable : :exception)
    end

    def perform(user_id)
      user = User.find_by(id: user_id)
      return log_outcome(:skipped, :missing_user) unless user

      status = ProfileSync.call(user:).status
      case status
      when :updated, :unchanged
        log_outcome(status, status)
      when :ineligible, :stale, :empty, :identity_mismatch, :missing_profile
        log_outcome(:skipped, status)
      when :invalid_data
        log_outcome(:failed, status)
      when :unavailable
        raise TemporarilyUnavailable, "Directory profile refresh temporarily unavailable", cause: nil
      else
        log_outcome(:failed, :unexpected_result)
      end
    end

    def retry_job(options = {})
      enqueued = super
      if enqueued
        log_outcome(:retrying, :unavailable)
      else
        log_outcome(:failed, :retry_enqueue_failed)
      end
      enqueued
    rescue StandardError
      log_outcome(:failed, :retry_enqueue_failed)
      raise
    end

    private

    def log_outcome(outcome, reason)
      Rails.logger.info("directory.profile_refresh job_id=#{job_id} attempt=#{executions} outcome=#{outcome} reason=#{reason}")
      nil
    end
  end
end
