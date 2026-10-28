class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :subject, polymorphic: true, optional: true

  validates :kind, presence: true

  scope :unread, -> { where(read_at: nil) }

  def read!
    update!(read_at: Time.current)
  end
end
