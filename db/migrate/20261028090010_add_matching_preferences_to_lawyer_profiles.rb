class AddMatchingPreferencesToLawyerProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :lawyer_profiles, :bar_admission_year, :integer
    add_column :lawyer_profiles, :court_preferences, :json, null: false, default: []
    add_column :lawyer_profiles, :availability_note, :string
  end
end
