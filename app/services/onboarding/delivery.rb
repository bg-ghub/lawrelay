module Onboarding
  class Delivery
    def self.request(user, email: true, directory: true)
      email_ready = !email || !user.email_verification_required? || enqueue { EmailVerificationMailer.verify(user).deliver_later }
      directory_ready = !directory || enqueue { Directory::VerificationJob.perform_later(user.id) }
      email_ready && directory_ready
    end

    def self.enqueue
      !!yield
    rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError, ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("Onboarding enqueue failed: #{error.class}")
      false
    end
  end
end
