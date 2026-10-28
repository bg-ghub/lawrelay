class AuditEvent < ApplicationRecord
  belongs_to :actor_user, class_name: "User", optional: true
  belongs_to :firm, optional: true
  belongs_to :auditable, polymorphic: true

  validates :action, presence: true
end
