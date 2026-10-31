require "securerandom"

class AddPublicIdToUsers < ActiveRecord::Migration[8.1]
  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    add_column :users, :public_id, :string
    add_index :users, :public_id, unique: true

    MigrationUser.reset_column_information
    MigrationUser.in_batches(of: 500) do |batch|
      batch.pluck(:id).each do |id|
        MigrationUser.where(id: id).update_all(public_id: SecureRandom.uuid)
      end
    end

    change_column_null :users, :public_id, false
  end

  def down
    remove_index :users, :public_id
    remove_column :users, :public_id
  end
end
