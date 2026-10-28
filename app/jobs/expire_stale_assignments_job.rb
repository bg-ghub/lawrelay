class ExpireStaleAssignmentsJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    Assignment.open.where(starts_at: ...now).find_each do |assignment|
      assignment.expire_if_stale!(now: now)
    end
  end
end
