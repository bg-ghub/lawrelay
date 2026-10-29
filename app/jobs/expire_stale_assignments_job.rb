class ExpireStaleAssignmentsJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    Assignment.open.where("response_deadline_at <= :now AND starts_at > :now", now:).find_each do |assignment|
      assignment.notify_response_deadline_if_due!(now:)
    end
    Assignment.open.where(starts_at: ..now).find_each do |assignment|
      assignment.expire_if_stale!(now: now)
    end
  end
end
