class AddEmailAccessReviewToLawyerProfiles < ActiveRecord::Migration[8.1]
  def up
    change_table :lawyer_profiles, bulk: true do |t|
      t.string :email_review_status
      t.string :email_review_email_address
      t.datetime :email_review_requested_at
      t.datetime :email_reviewed_at
      t.integer :email_reviewed_by_user_id
      t.text :email_review_note
      t.string :email_review_identity_digest
    end
    add_foreign_key :lawyer_profiles, :users, column: :email_reviewed_by_user_id
    add_index :lawyer_profiles, [ :email_review_status, :email_review_requested_at ], name: "index_lawyer_profiles_on_email_review_queue"
    remove_index :lawyer_profiles, :directory_profile_id
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND (directory_email_verified_at IS NOT NULL OR email_review_status = 'approved')"
  end

  def down
    remove_index :lawyer_profiles, :directory_profile_id
    add_index :lawyer_profiles, :directory_profile_id, unique: true,
      where: "directory_profile_id IS NOT NULL AND directory_email_verified_at IS NOT NULL"
    remove_index :lawyer_profiles, name: "index_lawyer_profiles_on_email_review_queue"
    remove_foreign_key :lawyer_profiles, column: :email_reviewed_by_user_id
    remove_columns :lawyer_profiles, :email_review_status, :email_review_email_address, :email_review_requested_at,
      :email_reviewed_at, :email_reviewed_by_user_id, :email_review_note, :email_review_identity_digest
  end
end
