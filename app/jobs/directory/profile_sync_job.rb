module Directory
  class ProfileSyncJob < ApplicationJob
    class TemporarilyUnavailable < StandardError; end

    queue_as :default
    limits_concurrency to: 1, key: "directory-profile-sync-provider", duration: 1.minute
    retry_on TemporarilyUnavailable, wait: 5.minutes, attempts: 3

    def perform(user_id)
      user = User.find_by(id: user_id)
      return unless user

      result = ProfileSync.call(user:)
      raise TemporarilyUnavailable, "Directory profile refresh temporarily unavailable", cause: nil if result.status == :unavailable
    end
  end
end
