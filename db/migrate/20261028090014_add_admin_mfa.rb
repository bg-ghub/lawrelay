class AddAdminMfa < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      t.string :admin_mfa_secret_ciphertext
      t.string :admin_mfa_pending_secret_ciphertext
      t.datetime :admin_mfa_enabled_at
      t.datetime :admin_mfa_last_verified_at
    end

    change_table :sessions, bulk: true do |t|
      t.datetime :admin_mfa_verified_at
      t.datetime :admin_mfa_challenged_at
    end
  end
end
