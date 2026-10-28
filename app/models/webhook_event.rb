class WebhookEvent < ApplicationRecord
  STATUSES = %w[received processing processed failed ignored].freeze

  validates :provider, :external_id, :payload_digest, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :external_id, uniqueness: { scope: :provider }

  def processed?
    status == "processed"
  end
end
