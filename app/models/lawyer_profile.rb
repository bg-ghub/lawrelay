class LawyerProfile < ApplicationRecord
  VERIFICATION_STATUSES = %w[pending verified rejected suspended].freeze

  belongs_to :user

  normalizes :bar_association, :bar_number, with: ->(value) { value.to_s.strip.upcase }
  normalizes :professional_email, with: ->(value) { value.to_s.strip.downcase.presence }
  normalizes :availability_note, with: ->(value) { value.to_s.strip.presence }

  before_validation :normalize_matching_preferences

  validates :bar_association, :bar_number, presence: true
  validates :bar_number, uniqueness: { scope: :bar_association }
  validates :verification_status, inclusion: { in: VERIFICATION_STATUSES }
  validates :bar_admission_year,
    numericality: { only_integer: true, greater_than_or_equal_to: 1900, less_than_or_equal_to: -> { Time.current.year } },
    allow_nil: true
  validates :availability_note, length: { maximum: 500 }, allow_nil: true

  def verified?
    verification_status == "verified" && verified_at.present?
  end

  private

  def normalize_matching_preferences
    self.court_preferences = Array(court_preferences)
      .flat_map { |value| value.to_s.split(",") }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end
end
