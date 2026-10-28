class Firm < ApplicationRecord
  VERIFICATION_STATUSES = %w[pending verified rejected suspended].freeze

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :assignments, dependent: :restrict_with_error
  has_many :proposals, dependent: :restrict_with_error
  has_one :billing_account, dependent: :destroy

  normalizes :name, with: ->(value) { value.strip }
  normalizes :enterprise_number, :vat_number, with: ->(value) { value.to_s.gsub(/[^A-Za-z0-9]/, "").upcase.presence }
  normalizes :billing_email, with: ->(value) { value.to_s.strip.downcase.presence }

  validates :name, presence: true, length: { maximum: 160 }
  validates :country_code, inclusion: { in: %w[BE] }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :enterprise_number, uniqueness: true, allow_nil: true
  validates :vat_number, uniqueness: true, allow_nil: true

  def verified?
    verification_status == "verified" && verified_at.present?
  end

  def posting_access?
    return true unless self.class.billing_enforced?

    billing_account&.posting_access? || false
  end

  def self.billing_enforced?(environment: Rails.env)
    return ActiveModel::Type::Boolean.new.cast(ENV["LAWRELAY_BILLING_ENFORCED"]) if ENV.key?("LAWRELAY_BILLING_ENFORCED")

    environment.production?
  end
end
