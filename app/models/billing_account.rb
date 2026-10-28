class BillingAccount < ApplicationRecord
  PROVIDERS = %w[manual mollie].freeze
  STATUSES = %w[pending active past_due suspended cancelled].freeze
  PLANS = %w[founding_beta lawrelay_office].freeze

  belongs_to :firm
  has_many :subscriptions, dependent: :restrict_with_error
  has_many :billing_payments, dependent: :restrict_with_error
  has_many :invoices, dependent: :restrict_with_error

  normalizes :billing_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :peppol_id, with: ->(value) { value.to_s.strip.presence }

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :plan_key, inclusion: { in: PLANS }
  validates :provider_customer_id, uniqueness: { scope: :provider }, allow_nil: true

  def current_subscription
    subscriptions.where(status: %w[trialing pending active past_due]).order(created_at: :desc).first
  end

  def posting_access?
    return false if status.in?(%w[past_due suspended cancelled])

    if plan_key == "founding_beta"
      status == "active" && complimentary_access_until.present? && complimentary_access_until.future?
    else
      current_subscription&.entitlement_active? || false
    end
  end
end
