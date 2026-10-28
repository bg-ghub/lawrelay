class AddAccountSuspensionToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :suspended_at, :datetime
    add_column :users, :suspension_reason, :text
    add_index :users, :suspended_at
  end
end
