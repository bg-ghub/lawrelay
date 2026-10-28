module Directory
  class ConfirmationJob < ApplicationJob
    queue_as :default

    def perform(profile_id)
      profile = LawyerProfile.find_by(id: profile_id)
      return unless profile&.directory_confirmation_required?

      DirectoryVerificationMailer.confirm(profile).deliver_now
      profile.update!(directory_confirmation_requested_at: Time.current)
    end
  end
end
