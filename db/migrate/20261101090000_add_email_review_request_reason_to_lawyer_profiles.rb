class AddEmailReviewRequestReasonToLawyerProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :lawyer_profiles, :email_review_request_reason, :text
  end
end
