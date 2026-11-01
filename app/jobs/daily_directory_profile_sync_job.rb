class DailyDirectoryProfileSyncJob < ApplicationJob
  BATCH_SIZE = 50

  queue_as :default
  limits_concurrency to: 1, key: "daily-directory-profile-sync", duration: 5.minutes

  def perform(after_user_id = 0, run_on = Time.current.utc.to_date.iso8601)
    return unless Date.iso8601(run_on.to_s) == Time.current.utc.to_date

    user_ids = User.where(system_role: "member", suspended_at: nil, erased_at: nil)
      .joins(:lawyer_profile).where.not(lawyer_profiles: { directory_profile_url: [ nil, "" ] })
      .where.not(lawyer_profiles: { directory_profile_id: [ nil, "" ] })
      .where.not(lawyer_profiles: { directory_name: [ nil, "" ] })
      .where.not(lawyer_profiles: { directory_email: [ nil, "" ] })
      .where.not(lawyer_profiles: { directory_checked_at: nil })
      .where.not(lawyer_profiles: { verification_status: %w[rejected suspended] })
      .where("users.id > ?", after_user_id.to_i).order("users.id ASC").limit(BATCH_SIZE).pluck(:id)
    user_ids.each_with_index do |user_id, index|
      Directory::ProfileSyncJob.set(wait: index.seconds).perform_later(user_id)
    end
    return unless user_ids.size == BATCH_SIZE

    self.class.set(wait: BATCH_SIZE.seconds).perform_later(user_ids.last, run_on)
  end
end
