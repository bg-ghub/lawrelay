require "net/http"

module Directory
  class VerificationJob < ApplicationJob
    queue_as :default
    retry_on Net::OpenTimeout, Net::ReadTimeout, SocketError, wait: :polynomially_longer, attempts: 3

    def perform(user_id)
      user = User.find_by(id: user_id)
      Verification.request!(user:) if user&.lawyer_profile&.directory_profile_url.present?
    end
  end
end
