require "net/http"

module Directory
  class VerificationJob < ApplicationJob
    class TemporarilyUnavailable < StandardError; end

    queue_as :default
    retry_on TemporarilyUnavailable, wait: 1.minute, attempts: 3

    def perform(user_id)
      user = User.find_by(id: user_id)
      return unless user&.active? && user.lawyer_profile&.directory_profile_url.present?

      result = Verification.request!(user:)
      raise TemporarilyUnavailable, "Directory lookup temporarily unavailable" if result.status == :unavailable
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError => error
      Rails.logger.warn("Directory lookup transport unavailable: #{error.class}")
      raise TemporarilyUnavailable, "Directory lookup temporarily unavailable", cause: nil
    end
  end
end
