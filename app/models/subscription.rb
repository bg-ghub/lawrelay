class Subscription < ApplicationRecord
  PROVIDERS = %w[manual mollie].freeze
  STATUSES = %w[trialing pending active past_due cancelled suspended].freeze
  PLAN_KEYS = %w[lawrelay_office].freeze

  belongs_to :billing_account
  has_many :billing_payments, dependent: :restrict_with_error
  has_many :invoices, dependent: :restrict_with_error

  before_validation :assign_idempotency_key, on: :create

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :plan_key, inclusion: { in: PLAN_KEYS }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[EUR] }
  validates :interval, inclusion: { in: %w[month] }
  validates :idempotency_key, presence: true, uniqueness: true

  def active?
    status == "active"
  end

  def entitlement_active?
    status.in?(%w[trialing active]) && current_period_ends_at.present? && current_period_ends_at.future?
  end

  def terminal?
    status.in?(%w[cancelled suspended])
  end

  def cancel!
    update!(status: "cancelled", cancelled_at: Time.current)
  end

  private

  def assign_idempotency_key
    self.idempotency_key ||= SecureRandom.uuid
  end
end
