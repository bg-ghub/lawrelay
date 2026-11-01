class AddDirectoryLocationToLawyerProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :lawyer_profiles, :directory_professional_address, :string, limit: 500
    add_column :lawyer_profiles, :directory_bar_name, :string, limit: 200
  end
end
