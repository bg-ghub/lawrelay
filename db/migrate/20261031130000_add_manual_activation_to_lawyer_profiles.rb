class AddManualActivationToLawyerProfiles < ActiveRecord::Migration[8.1]
  def up
    add_column :lawyer_profiles, :manual_activation_approved_at, :datetime
    add_reference :lawyer_profiles, :manual_activation_approved_by_user, foreign_key: { to_table: :users }
    add_column :lawyer_profiles, :manual_activation_identity_digest, :string

    remove_index :lawyer_profiles, :directory_profile_id
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND (directory_email_verified_at IS NOT NULL OR email_review_status = 'approved' OR manual_activation_approved_at IS NOT NULL)"
  end

  def down
    remove_index :lawyer_profiles, :directory_profile_id
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND (directory_email_verified_at IS NOT NULL OR email_review_status = 'approved')"

    remove_column :lawyer_profiles, :manual_activation_identity_digest
    remove_reference :lawyer_profiles, :manual_activation_approved_by_user, foreign_key: { to_table: :users }
    remove_column :lawyer_profiles, :manual_activation_approved_at
  end
end
