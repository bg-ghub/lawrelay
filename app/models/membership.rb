class Membership < ApplicationRecord
  ROLES = %w[owner admin member].freeze

  belongs_to :user
  belongs_to :firm

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :firm_id }

  def administrator?
    role.in?(%w[owner admin])
  end
end
