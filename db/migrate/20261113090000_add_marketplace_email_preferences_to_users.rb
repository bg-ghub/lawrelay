class AddMarketplaceEmailPreferencesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :new_assignment_alerts, :boolean, default: false, null: false
    add_column :users, :assignment_update_emails, :boolean, default: true, null: false
  end
end
