class Invoice < ApplicationRecord
  STATUSES = %w[draft issued paid void overdue].freeze
  PEPPOL_STATUSES = %w[not_requested manual_required queued sent accepted rejected].freeze

  belongs_to :billing_account
  belongs_to :subscription, optional: true

  before_validation :recalculate_totals

  validates :status, inclusion: { in: STATUSES }
  validates :peppol_status, inclusion: { in: PEPPOL_STATUSES }
  validates :currency, inclusion: { in: %w[EUR] }
  validates :subtotal_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :vat_rate_basis_points, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :number, uniqueness: true, allow_nil: true

  def issue!
    with_lock do
      self.number ||= Billing::InvoiceNumber.next
      self.status = "issued"
      self.issued_on ||= Date.current
      self.due_on ||= issued_on + 30.days
      save!
    end
  end

  def mark_paid!(date = Date.current)
    update!(status: "paid", paid_on: date)
  end

  private

  def recalculate_totals
    self.vat_cents = (subtotal_cents.to_i * vat_rate_basis_points.to_i / 10_000.0).round
    self.total_cents = subtotal_cents.to_i + vat_cents.to_i
  end
end
