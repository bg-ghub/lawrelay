class OnlyUniqueVerifiedDirectoryClaims < ActiveRecord::Migration[8.1]
  def change
    remove_index :lawyer_profiles, name: "index_lawyer_profiles_on_directory_profile_id"
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND directory_email_verified_at IS NOT NULL"
  end
end
