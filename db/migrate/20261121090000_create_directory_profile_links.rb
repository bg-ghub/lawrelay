class CreateDirectoryProfileLinks < ActiveRecord::Migration[8.1]
  class StoredProfile < ActiveRecord::Base
    self.table_name = "lawyer_profiles"
  end

  class StoredLink < ActiveRecord::Base
    self.table_name = "directory_profile_links"
  end

  def up
    create_table :directory_profile_links do |t|
      t.references :lawyer_profile, null: false, foreign_key: { on_delete: :cascade }
      t.string :directory_profile_id, null: false, limit: 36, collation: "NOCASE"
      t.index :directory_profile_id, unique: true
    end

    uuid = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
    url = %r{\Ahttps://(?:www\.)?advocaat\.be(?::443)?/nl/zoek-een-advocaat/advocaat/([^/]+)\z}i
    owners = Hash.new { |all, id| all[id] = Set.new }
    StoredProfile.find_each do |profile|
      [ profile.directory_profile_id, profile.directory_profile_url.to_s[url, 1] ].compact.each do |id|
        owners[id.downcase] << profile.id if uuid.match?(id.downcase)
      end
    end
    # Existing ambiguities need individual review. Runtime checks also consult
    # their original records so a third signup cannot acquire an ambiguous ID.
    owners.each do |id, profiles|
      StoredLink.create!(directory_profile_id: id, lawyer_profile_id: profiles.first) if profiles.one?
    end
  end

  def down
    drop_table :directory_profile_links
  end
end
