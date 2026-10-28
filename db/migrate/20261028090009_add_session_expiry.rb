class AddSessionExpiry < ActiveRecord::Migration[8.1]
  def up
    add_column :sessions, :expires_at, :datetime
    add_column :sessions, :last_seen_at, :datetime
    execute "UPDATE sessions SET expires_at = datetime(created_at, '+30 days'), last_seen_at = updated_at"
    change_column_null :sessions, :expires_at, false
    add_index :sessions, :expires_at
  end

  def down
    remove_index :sessions, :expires_at
    remove_column :sessions, :last_seen_at
    remove_column :sessions, :expires_at
  end
end
