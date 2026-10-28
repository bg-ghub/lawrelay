class AddMarketplaceOwnershipAndAuditing < ActiveRecord::Migration[8.1]
  def change
    add_reference :assignments, :creator_user, foreign_key: { to_table: :users }
    add_reference :assignments, :firm, foreign_key: true
    add_column :assignments, :lock_version, :integer, null: false, default: 0

    add_reference :proposals, :user, foreign_key: true
    add_reference :proposals, :firm, foreign_key: true
    add_column :proposals, :accepted_at, :datetime
    add_column :proposals, :declined_at, :datetime
    add_column :proposals, :withdrawn_at, :datetime
    change_column_null :proposals, :name, true
    change_column_null :proposals, :email, true
    add_index :proposals, %i[assignment_id user_id], unique: true, where: "user_id IS NOT NULL"
    add_index :proposals, :assignment_id, unique: true, where: "status = 'accepted'", name: "index_proposals_on_one_accepted_per_assignment"

    create_table :audit_events do |t|
      t.references :actor_user, foreign_key: { to_table: :users }
      t.references :firm, foreign_key: true
      t.references :auditable, polymorphic: true, null: false
      t.string :action, null: false
      t.json :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end
    add_index :audit_events, %i[auditable_type auditable_id created_at], name: "index_audit_events_on_subject_and_time"

    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true
      t.references :subject, polymorphic: true
      t.string :kind, null: false
      t.json :data, null: false, default: {}
      t.datetime :read_at
      t.timestamps
    end
    add_index :notifications, %i[user_id read_at]
  end
end
