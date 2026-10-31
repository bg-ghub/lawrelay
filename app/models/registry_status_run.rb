class RegistryStatusRun < ApplicationRecord
  RUN_LEASE = 5.minutes
  ALERT_LEASE = 10.minutes
  MAX_ALERT_ATTEMPTS = 5
  ALERT_RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze

  validates :run_on, presence: true
  validates :status, inclusion: { in: %w[pending running completed] }
  validates :alert_status, inclusion: { in: %w[pending sending sent failed] }, allow_nil: true

  def claim!(now: Time.current)
    with_lock do
      next if status == "completed" || (status == "running" && lease_expires_at && lease_expires_at > now)

      token = SecureRandom.uuid
      update!(status: "running", lease_token: token, lease_expires_at: now + RUN_LEASE, started_at: started_at || now)
      token
    end
  end

  def current_lease?(token, now: Time.current)
    self.class.where(id:, status: "running", lease_token: token).where("lease_expires_at > ?", now).exists?
  end

  def release!(token)
    self.class.where(id:, status: "running", lease_token: token).update_all(
      status: "pending", lease_token: nil, lease_expires_at: nil, updated_at: Time.current)
  end

  def complete!(token, now: Time.current)
    with_lock do
      next false unless lease_token == token && status == "running"

      update!(status: "completed", completed_at: now, lease_token: nil, lease_expires_at: nil,
        alert_status: findings.any? ? "pending" : nil)
      true
    end
  end

  def complete_stale!(now: Time.current)
    with_lock do
      next false if status == "completed" || run_on >= now.utc.to_date

      update!(status: "completed", completed_at: now, lease_token: nil, lease_expires_at: nil,
        alert_status: findings.any? ? "pending" : nil)
      true
    end
  end

  def new_findings_count
    finding_checks.count
  end

  def finding_checks
    RegistryStatusCheck.relevant.where(id: findings.filter_map { |finding| finding["check_id"] }).includes(lawyer_profile: :user)
  end

  def discard_irrelevant_findings!
    with_lock do
      current = finding_checks.index_by(&:id)
      remaining = findings.filter_map do |finding|
        check = current[finding["check_id"]]
        check.sanitize_finding(finding) if check
      end
      attributes = { findings: remaining }
      attributes.merge!(alert_status: nil, alert_claimed_at: nil, alert_retry_at: nil) if remaining.empty? && alert_status != "sent"
      update!(attributes) if remaining != findings || attributes.key?(:alert_status)
    end
  end

  def self.deliverable_alerts(now: Time.current)
    where(status: "completed").where(
      "(alert_status = :pending AND (alert_retry_at IS NULL OR alert_retry_at <= :now)) OR " \
      "(alert_status = :sending AND alert_claimed_at <= :cutoff)",
      pending: "pending", sending: "sending", now:, cutoff: now - ALERT_LEASE)
  end

  def self.alert_delivery_unhealthy?(now: Time.current)
    where(alert_status: "failed").exists? ||
      where(alert_status: "pending").where("COALESCE(alert_retry_at, created_at) < ?", now - 15.minutes).exists? ||
      where(alert_status: "sending").where("alert_claimed_at < ?", now - ALERT_LEASE).exists?
  end

  def claim_alert_delivery!(now: Time.current)
    with_lock do
      due = (alert_status == "pending" && (alert_retry_at.nil? || alert_retry_at <= now)) ||
        (alert_status == "sending" && alert_claimed_at && alert_claimed_at <= now - ALERT_LEASE)
      next false unless status == "completed" && findings.any? && due

      if alert_attempts >= MAX_ALERT_ATTEMPTS
        update!(alert_status: "failed", alert_status_reason: "attempt_limit", alert_claimed_at: nil)
        next false
      end
      update!(alert_status: "sending", alert_attempts: alert_attempts + 1,
        alert_claimed_at: now, alert_retry_at: nil, alert_status_reason: nil)
      true
    end
  end

  def current_alert_claim?
    current_alert_claim.exists?
  end

  def finish_alert_delivery!(now: Time.current)
    self.class.transaction do
      updated = current_alert_claim.update_all(alert_status: "sent", alert_sent_at: now,
        alert_claimed_at: nil, alert_retry_at: nil, updated_at: now)
      if updated.positive?
        findings.each do |finding|
          next unless finding["issue_since"]

          RegistryStatusCheck.where(id: finding["check_id"], issue_status: finding["status"],
            issue_since: Time.iso8601(finding["issue_since"])).update_all(last_alerted_at: now, updated_at: now)
        end
      end
    end
  end

  def fail_alert_delivery!(error:, now: Time.current)
    exhausted = alert_attempts >= MAX_ALERT_ATTEMPTS
    delay = ALERT_RETRY_DELAYS.fetch(alert_attempts - 1, ALERT_RETRY_DELAYS.last)
    current_alert_claim.update_all(alert_status: exhausted ? "failed" : "pending",
      alert_status_reason: error.class.name, alert_claimed_at: nil,
      alert_retry_at: (now + delay unless exhausted), updated_at: now)
  end

  private

  def current_alert_claim
    self.class.where(id:, alert_status: "sending", alert_claimed_at:)
  end
end
