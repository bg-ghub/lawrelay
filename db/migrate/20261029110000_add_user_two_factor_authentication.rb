class AddUserTwoFactorAuthentication < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :two_factor_secret_ciphertext
      t.string :two_factor_pending_secret_ciphertext
      t.datetime :two_factor_enabled_at
      t.datetime :two_factor_last_verified_at
      t.json :two_factor_recovery_code_digests, default: [], null: false
    end

    add_column :sessions, :two_factor_verified_at, :datetime
  end
end
