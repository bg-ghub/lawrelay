require "digest"

class AccountDeletionRequest < ApplicationRecord
  NOTICE_KINDS = %w[requested cancelled].freeze
  NOTICE_COLUMNS = {
    "requested" => { status: :requested_email_status, retry_at: :requested_email_retry_at,
      claimed_at: :requested_email_claimed_at, enqueued_at: :requested_email_enqueued_at }.freeze,
    "cancelled" => { status: :cancelled_email_status, retry_at: :cancelled_email_retry_at,
      claimed_at: :cancelled_email_claimed_at, enqueued_at: :cancelled_email_enqueued_at }.freeze
  }.freeze
  EMAIL_STATUSES = %w[pending sending sent skipped failed].freeze
  FINALIZATION_STATUSES = %w[pending sending completed cancelled failed paused].freeze
  LEASE = 10.minutes
  MAX_ATTEMPTS = 5
  RETRY_DELAYS = [ 1.minute, 5.minutes, 15.minutes, 1.hour ].freeze

  belongs_to :user
  belongs_to :privacy_request, optional: true
  has_many :audit_events, as: :auditable, dependent: :destroy

  validates :requested_at, :scheduled_at, presence: true
  validates :finalization_status, inclusion: { in: FINALIZATION_STATUSES }
  validates :requested_email_status, :cancelled_email_status, inclusion: { in: EMAIL_STATUSES }, allow_nil: true
  validates :email_identity_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :grace_period_is_complete

  scope :pending, -> { where(cancelled_at: nil, completed_at: nil) }
  scope :due, ->(now = Time.current) { pending.where(scheduled_at: ..now) }

  def paused?
    finalization_status == "paused"
  end

  def current_cycle?(member = user)
    cancelled_at.nil? && completed_at.nil? && member.erased_at.nil? &&
      member.deletion_request_id == id && member.deletion_requested_at == requested_at &&
      member.deletion_scheduled_at == scheduled_at
  end

  def notice_eligible?(kind, user: self.user)
    validate_notice_kind!(kind)
    return false if user.system_admin? || user.suspended? || user.erased_at || email_identity_digest.blank?
    digest = Digest::SHA256.hexdigest(user.email_address)
    return false unless ActiveSupport::SecurityUtils.secure_compare(email_identity_digest, digest)

    if kind == "requested"
      current_cycle?(user) && !paused?
    else
      cancelled_at.present? && completed_at.nil? && user.active? && !user.deletion_pending?
    end
  end

  def self.deliverable_notices(kind, now: Time.current)
    columns = notice_columns(kind)
    status = arel_table[columns.fetch(:status)]
    retry_at = arel_table[columns.fetch(:retry_at)]
    claimed_at = arel_table[columns.fetch(:claimed_at)]
    where(status.eq("pending").and(retry_at.eq(nil).or(retry_at.lteq(now)))
      .or(status.eq("sending").and(claimed_at.lteq(now - LEASE))))
  end

  def claim_notice!(kind, now: Time.current)
    validate_notice_kind!(kind)
    with_lock do
      next false unless self.class.deliverable_notices(kind, now:).exists?(id:)
      attempts = public_send("#{kind}_email_attempts")
      if attempts >= MAX_ATTEMPTS
        update!("#{kind}_email_status" => "failed", "#{kind}_email_reason" => "attempt_limit", "#{kind}_email_claimed_at" => nil)
        next false
      end
      update!("#{kind}_email_status" => "sending", "#{kind}_email_attempts" => attempts + 1,
        "#{kind}_email_claimed_at" => now, "#{kind}_email_enqueued_at" => nil,
        "#{kind}_email_retry_at" => nil, "#{kind}_email_reason" => nil)
      true
    end
  end

  def reserve_notice_enqueue!(kind, now: Time.current)
    validate_notice_kind!(kind)
    with_lock do
      next false unless self.class.deliverable_notices(kind, now:).exists?(id:)
      reserved_at = public_send("#{kind}_email_enqueued_at")
      next false if reserved_at && reserved_at > now - LEASE

      update!("#{kind}_email_enqueued_at" => now)
      true
    end
  end

  def release_notice_enqueue!(kind)
    column = self.class.notice_columns(kind).fetch(:enqueued_at)
    self.class.where(id:).where(self.class.arel_table[column].eq(public_send(column)))
      .update_all("#{kind}_email_enqueued_at" => nil)
  end

  def finish_notice!(kind, status:, reason: nil, now: Time.current)
    raise ArgumentError, "Invalid notice completion" unless status.in?(%w[sent skipped])
    notice_claim(kind).update_all("#{kind}_email_status" => status, "#{kind}_email_reason" => reason,
      "#{kind}_email_sent_at" => (now if status == "sent"), "#{kind}_email_claimed_at" => nil,
      "#{kind}_email_retry_at" => nil, updated_at: now)
  end

  def notice_claim_current?(kind)
    notice_claim(kind).exists?
  end

  def fail_notice!(kind, error:, now: Time.current)
    attempts = public_send("#{kind}_email_attempts")
    exhausted = attempts >= MAX_ATTEMPTS
    delay = RETRY_DELAYS.fetch(attempts - 1, RETRY_DELAYS.last)
    notice_claim(kind).update_all("#{kind}_email_status" => exhausted ? "failed" : "pending",
      "#{kind}_email_reason" => error.class.name, "#{kind}_email_claimed_at" => nil,
      "#{kind}_email_retry_at" => exhausted ? nil : now + delay, updated_at: now)
  end

  def claim_finalization!(now: Time.current)
    with_lock do
      due = scheduled_at <= now && cancelled_at.nil? && completed_at.nil? &&
        ((finalization_status == "pending" && (finalization_retry_at.nil? || finalization_retry_at <= now)) ||
         (finalization_status == "sending" && finalization_claimed_at && finalization_claimed_at <= now - LEASE))
      next false unless due
      if finalization_attempts >= MAX_ATTEMPTS
        update!(finalization_status: "failed", finalization_reason: "attempt_limit", finalization_claimed_at: nil)
        next false
      end
      update!(finalization_status: "sending", finalization_attempts: finalization_attempts + 1,
        finalization_claimed_at: now, finalization_enqueued_for: nil, finalization_retry_at: nil, finalization_reason: nil)
      true
    end
  end

  def reserve_finalization_enqueue!(now: Time.current)
    with_lock do
      next unless cancelled_at.nil? && completed_at.nil?
      next unless finalization_status == "pending" ||
        (finalization_status == "sending" && finalization_claimed_at && finalization_claimed_at <= now - LEASE)
      next if finalization_enqueued_for && finalization_enqueued_for > now - LEASE

      target = [ scheduled_at, finalization_retry_at, now ].compact.max
      update!(finalization_enqueued_for: target)
      target
    end
  end

  def release_finalization_enqueue!
    self.class.where(id:, finalization_enqueued_for:).update_all(finalization_enqueued_for: nil)
  end

  def fail_finalization!(error:, now: Time.current)
    exhausted = finalization_attempts >= MAX_ATTEMPTS
    delay = RETRY_DELAYS.fetch(finalization_attempts - 1, RETRY_DELAYS.last)
    finalization_claim.update_all(finalization_status: exhausted ? "failed" : "pending",
      finalization_reason: error.class.name, finalization_claimed_at: nil,
      finalization_retry_at: exhausted ? nil : now + delay, updated_at: now)
  end

  def self.unhealthy?(now: Time.current)
    return true if joins(:privacy_request).where.not(cancelled_at: nil)
      .where(privacy_requests: { status: %w[pending in_review] }).where("account_deletion_requests.cancelled_at < ?", now - 15.minutes).exists?
    return true if pending.where(finalization_status: "failed").exists?
    return true if pending.where(finalization_status: "paused", finalization_reason: "review_required").exists?
    return true if pending.where.not(finalization_status: "paused").where(scheduled_at: ..(now - 15.minutes)).exists?

    NOTICE_KINDS.any? do |kind|
      columns = notice_columns(kind)
      status = arel_table[columns.fetch(:status)]
      retry_at = arel_table[columns.fetch(:retry_at)]
      claimed_at = arel_table[columns.fetch(:claimed_at)]
      overdue = retry_at.lt(now - 15.minutes).or(retry_at.eq(nil).and(arel_table[:created_at].lt(now - 15.minutes)))
      where(status.eq("failed")).exists? || where(status.eq("pending").and(overdue)).exists? ||
        where(status.eq("sending").and(claimed_at.lt(now - LEASE))).exists?
    end
  end

  def self.validate_notice_kind!(kind)
    raise ArgumentError, "Invalid account deletion notice" unless NOTICE_KINDS.include?(kind)
  end

  def self.notice_columns(kind)
    validate_notice_kind!(kind)
    NOTICE_COLUMNS.fetch(kind)
  end

  private

  def validate_notice_kind!(kind)
    self.class.validate_notice_kind!(kind)
  end

  def notice_claim(kind)
    columns = self.class.notice_columns(kind)
    table = self.class.arel_table
    self.class.where(id:).where(table[columns.fetch(:status)].eq("sending"))
      .where(table[columns.fetch(:claimed_at)].eq(public_send(columns.fetch(:claimed_at))))
  end

  def finalization_claim
    self.class.where(id:, finalization_status: "sending", finalization_claimed_at:)
  end

  def grace_period_is_complete
    return unless requested_at && scheduled_at && scheduled_at < requested_at + 30.days

    errors.add(:scheduled_at, :invalid)
  end
end
