class AddDirectoryVerificationToLawyerProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :lawyer_profiles, bulk: true do |t|
      t.string :directory_profile_url
      t.string :directory_profile_id
      t.string :directory_name
      t.string :directory_email
      t.datetime :directory_checked_at
      t.datetime :directory_email_verified_at
      t.datetime :directory_confirmation_requested_at
      t.string :directory_identity_digest
    end
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND directory_email_verified_at IS NOT NULL"
  end
end
