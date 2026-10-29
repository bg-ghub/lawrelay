class AddNotificationEmailOutbox < ActiveRecord::Migration[8.1]
  def change
    change_table :notifications, bulk: true do |t|
      t.string :event_key
      t.string :email_status
      t.integer :email_attempts, default: 0, null: false
      t.datetime :email_claimed_at
      t.datetime :email_sent_at
      t.datetime :email_retry_at
      t.string :email_status_reason
    end

    add_index :notifications, :event_key, unique: true, where: "event_key IS NOT NULL"
    add_index :notifications, [ :email_status, :email_retry_at ], name: "index_notifications_on_email_delivery"
  end
end
