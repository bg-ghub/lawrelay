class Firm < ApplicationRecord
  # A workspace groups permissions and verification without collecting a legal identity.
  INTERNAL_WORKSPACE_NAME = "Workspace".freeze
  VERIFICATION_STATUSES = %w[pending verified rejected suspended].freeze

  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :assignments, dependent: :restrict_with_error
  has_many :proposals, dependent: :restrict_with_error
  has_one :billing_account, dependent: :destroy

  normalizes :name, with: ->(value) { value.strip }
  normalizes :billing_email, with: ->(value) { value.to_s.strip.downcase.presence }

  validates :name, presence: true, length: { maximum: 160 }
  validates :address_line_1, length: { maximum: 200 }, allow_blank: true
  validates :postal_code, length: { maximum: 12 }, allow_blank: true
  validates :city, length: { maximum: 100 }, allow_blank: true
  validates :country_code, inclusion: { in: %w[BE] }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validate :enterprise_number_is_present_for_company_details
  validate :enterprise_number_is_valid
  validate :vat_number_is_derived

  def enterprise_number=(value)
    normalized = self.class.normalize_enterprise_number(value)
    write_attribute(:enterprise_number, normalized)
    write_attribute(:vat_number, self.class.vat_number_for(normalized))
  end

  # VAT is always derived from the Belgian enterprise number. Keeping this
  # writer defensive also protects non-form callers from storing a different
  # submitted VAT number.
  def vat_number=(_value)
    write_attribute(:vat_number, self.class.vat_number_for(enterprise_number))
  end

  def verified?
    verification_status == "verified" && verified_at.present?
  end

  def posting_access?
    return verified? if self.class.beta_mode?

    return true unless self.class.billing_enforced?

    billing_account&.posting_access? || false
  end

  def self.beta_mode?
    ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "beta"
  end

  def self.billing_enforced?(environment: Rails.env)
    return ActiveModel::Type::Boolean.new.cast(ENV["LAWRELAY_BILLING_ENFORCED"]) if ENV.key?("LAWRELAY_BILLING_ENFORCED")

    environment.production?
  end

  def self.normalize_enterprise_number(value)
    candidate = value.to_s.strip.upcase
    compact = candidate.gsub(/[.\s-]/, "")
    compact = compact.delete_prefix("BE") if compact.match?(/\ABE\d+\z/)
    compact.presence
  end

  def self.vat_number_for(enterprise_number)
    number = enterprise_number.to_s
    "BE#{number}" if number.match?(/\A\d{10}\z/)
  end

  def self.valid_enterprise_number?(value)
    number = normalize_enterprise_number(value).to_s
    number.match?(/\A\d{10}\z/) && number.last(2).to_i == 97 - (number.first(8).to_i % 97)
  end

  private

  def enterprise_number_is_valid
    return unless company_details_validation?
    return if enterprise_number.blank?

    errors.add(:enterprise_number, :invalid) unless self.class.valid_enterprise_number?(enterprise_number)
  end

  def vat_number_is_derived
    return unless company_details_validation?
    return if vat_number == self.class.vat_number_for(enterprise_number)

    errors.add(:vat_number, :invalid)
  end

  def enterprise_number_is_present_for_company_details
    return unless company_details_validation?

    errors.add(:enterprise_number, :blank) if enterprise_number.blank?
  end

  def company_details_validation?
    validation_context == :company_details
  end
end
