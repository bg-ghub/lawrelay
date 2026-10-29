module Directory
  class ConfirmationJob < ApplicationJob
    queue_as :default
    retry_on Onboarding::MailTransport::TemporaryFailure, wait: 1.minute, attempts: 3

    def perform(profile_id)
      profile = LawyerProfile.find_by(id: profile_id)
      return unless profile&.user&.active? && profile.directory_confirmation_required?

      delivery = DirectoryVerificationMailer.confirm(profile)
      Onboarding::MailTransport.protect(delivery.message)
      delivery.deliver_now
      profile.update!(directory_confirmation_requested_at: Time.current)
    end
  end
end
