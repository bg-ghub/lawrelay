class AddReleaseSafetyFields < ActiveRecord::Migration[8.1]
  def change
    add_column :assignments, :content_rules_accepted_at, :datetime
    add_column :billing_accounts, :complimentary_access_until, :datetime
  end
end
