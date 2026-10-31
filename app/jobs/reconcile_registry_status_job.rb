class ReconcileRegistryStatusJob < ApplicationJob
  queue_as :default

  def perform(now: Time.current)
    utc = now.utc
    RegistryStatusRun.where.not(status: "completed").where("run_on < ?", utc.to_date).find_each do |run|
      run.complete_stale!(now:)
    end
    current = RegistryStatusRun.where(run_on: utc.to_date)
    current.where(status: "pending").or(
      current.where(status: "running").where("lease_expires_at <= ?", now)
    ).find_each do |run|
      DailyRegistryStatusJob.perform_later(run.run_on.iso8601)
    end
    RegistryStatusRun.deliverable_alerts(now:).find_each do |run|
      RegistryStatusAlertJob.perform_later(run.id)
    end
    # Recover a missed daily scheduler tick after a server restart.
    if utc.hour >= 5 && !RegistryStatusRun.exists?(run_on: utc.to_date)
      DailyRegistryStatusJob.perform_later(utc.to_date.iso8601)
    end
  end
end
