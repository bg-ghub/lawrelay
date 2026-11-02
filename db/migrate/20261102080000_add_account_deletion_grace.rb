class AddAccountDeletionGrace < ActiveRecord::Migration[8.1]
  def up
    create_table :account_deletion_requests do |t|
      t.references :user, null: false, foreign_key: true
      t.references :privacy_request, foreign_key: { on_delete: :nullify }
      t.datetime :requested_at, null: false
      t.datetime :scheduled_at, null: false
      t.datetime :cancelled_at
      t.datetime :completed_at
      t.string :email_identity_digest
      t.string :finalization_status, default: "pending", null: false
      t.integer :finalization_attempts, default: 0, null: false
      t.datetime :finalization_claimed_at
      t.datetime :finalization_enqueued_for
      t.datetime :finalization_retry_at
      t.string :finalization_reason
      %w[requested cancelled].each do |kind|
        t.string "#{kind}_email_status"
        t.integer "#{kind}_email_attempts", default: 0, null: false
        t.datetime "#{kind}_email_claimed_at"
        t.datetime "#{kind}_email_enqueued_at"
        t.datetime "#{kind}_email_retry_at"
        t.datetime "#{kind}_email_sent_at"
        t.string "#{kind}_email_reason"
      end
      t.timestamps
    end
    add_index :account_deletion_requests, :scheduled_at
    add_index :account_deletion_requests, :user_id, unique: true,
      where: "cancelled_at IS NULL AND completed_at IS NULL", name: "one_pending_account_deletion_per_user"
    add_reference :users, :deletion_request, foreign_key: { to_table: :account_deletion_requests, on_delete: :nullify }
    add_column :users, :deletion_requested_at, :datetime
    add_column :users, :deletion_scheduled_at, :datetime
  end

  def down
    if select_value("SELECT 1 FROM account_deletion_requests LIMIT 1") ||
       select_value("SELECT 1 FROM users WHERE deletion_requested_at IS NOT NULL OR deletion_scheduled_at IS NOT NULL OR deletion_request_id IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Pending deletion requests must remain disabled; use a compatible forward fix."
    end
    remove_column :users, :deletion_requested_at
    remove_column :users, :deletion_scheduled_at
    remove_reference :users, :deletion_request, foreign_key: { to_table: :account_deletion_requests }
    drop_table :account_deletion_requests
  end
end
