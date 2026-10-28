class BillingPayment < ApplicationRecord
  PROVIDERS = %w[manual mollie].freeze
  STATUSES = %w[pending open paid failed expired cancelled refunded charged_back].freeze

  belongs_to :billing_account
  belongs_to :subscription, optional: true

  before_validation :assign_idempotency_key, on: :create

  validates :provider, inclusion: { in: PROVIDERS }
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, inclusion: { in: %w[EUR] }
  validates :idempotency_key, presence: true, uniqueness: true
  validates :provider_payment_id, uniqueness: { scope: :provider }, allow_nil: true

  def paid!
    update!(status: "paid", paid_at: Time.current)
  end

  def refunded!
    update!(status: "refunded", refunded_at: Time.current)
  end

  def charged_back!
    update!(status: "charged_back")
  end

  private

  def assign_idempotency_key
    self.idempotency_key ||= SecureRandom.uuid
  end
end
