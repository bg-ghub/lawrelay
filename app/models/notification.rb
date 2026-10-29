class Notification < ApplicationRecord
  EMAIL_KINDS = %w[new_proposal proposal_accepted proposal_declined proposal_withdrawn assignment_matched
    assignment_cancelled assignment_completed assignment_expired response_deadline_closed].freeze
  EMAIL_STATUSES = %w[pending sending sent skipped failed].freeze
  EMAIL_LEASE = 10.minutes
  MAX_EMAIL_ATTEMPTS = 5
  EMAIL_RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze

  belongs_to :user
  belongs_to :subject, polymorphic: true, optional: true

  validates :kind, presence: true
  validates :kind, inclusion: { in: EMAIL_KINDS }, if: -> { event_key.present? }
  validates :email_status, inclusion: { in: EMAIL_STATUSES }, allow_nil: true
  after_create_commit :enqueue_email, if: -> { event_key.present? && email_status == "pending" }

  scope :unread, -> { where(read_at: nil) }
  # Existing notifications deliberately have no event_key or delivery status.
  # Their historic email outcome is unknown, so they must never be backfilled.
  scope :email_outbox, -> { where.not(event_key: nil).where.not(email_status: nil) }

  def self.publish!(user:, kind:, subject:, assignment:, actor: nil)
    return unless user && user.id != actor&.id

    event_key = [ kind, subject.class.base_class.name, subject.id, user.id ].join(":")
    create_or_find_by!(event_key:) do |notification|
      notification.assign_attributes(user:, kind:, subject:, data: { assignment_id: assignment.id }, email_status: "pending")
    end
  end

  def self.deliverable_emails(now: Time.current)
    email_outbox.where(
      "(email_status = :pending AND (email_retry_at IS NULL OR email_retry_at <= :now)) OR " \
      "(email_status = :sending AND email_claimed_at <= :lease_cutoff)",
      pending: "pending", sending: "sending", now:, lease_cutoff: now - EMAIL_LEASE
    )
  end

  def self.email_delivery_unhealthy?(now: Time.current)
    email_outbox.where(email_status: "failed").exists? ||
      email_outbox.where(email_status: "pending").where(
        "COALESCE(email_retry_at, created_at) < ?", now - 15.minutes
      ).exists? ||
      email_outbox.where(email_status: "sending").where("email_claimed_at < ?", now - EMAIL_LEASE).exists?
  end

  def claim_email_delivery!(now: Time.current)
    with_lock do
      due = (email_status == "pending" && (email_retry_at.nil? || email_retry_at <= now)) ||
        (email_status == "sending" && email_claimed_at.present? && email_claimed_at <= now - EMAIL_LEASE)
      next false unless event_key.present? && due

      if email_attempts >= MAX_EMAIL_ATTEMPTS
        update!(email_status: "failed", email_status_reason: "attempt_limit", email_claimed_at: nil)
        next false
      end

      update!(email_status: "sending", email_attempts: email_attempts + 1,
        email_claimed_at: now, email_retry_at: nil, email_status_reason: nil)
      true
    end
  end

  def finish_email_delivery!(status:, reason: nil, now: Time.current)
    current_email_claim.update_all(email_status: status, email_status_reason: reason,
      email_sent_at: (now if status == "sent"), email_claimed_at: nil, email_retry_at: nil, updated_at: now)
  end

  def current_email_delivery_claim?
    current_email_claim.exists?
  end

  def fail_email_delivery!(error:, now: Time.current)
    exhausted = email_attempts >= MAX_EMAIL_ATTEMPTS
    delay = EMAIL_RETRY_DELAYS.fetch(email_attempts - 1, EMAIL_RETRY_DELAYS.last)
    current_email_claim.update_all(email_status: exhausted ? "failed" : "pending",
      email_status_reason: error.class.name, email_claimed_at: nil,
      email_retry_at: (now + delay unless exhausted), updated_at: now)
  end

  def read!
    update!(read_at: Time.current)
  end

  private

  def current_email_claim
    self.class.where(id:, email_status: "sending", email_claimed_at:)
  end

  def enqueue_email
    NotificationEmailDeliveryJob.perform_later(id)
  rescue StandardError => error
    # The persisted outbox is reconciled separately if the queue is unavailable.
    Rails.logger.error("Notification email enqueue failed: #{error.class} (notification #{id})")
  end
end
