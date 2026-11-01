require "digest"

class CourtHearingLocations
  DATA = JSON.parse(Rails.root.join("config/court_hearing_locations.be.json").read).freeze
  CATALOGUE_SHA256 = Digest::SHA256.hexdigest(JSON.generate(CourtCatalogue::DATA)).freeze
  Details = Data.define(:court_name, :address)

  def self.available?
    DATA["schema_version"] == 1 && DATA["catalogue_hash_format"] == "parsed-json-v1" && DATA["catalogue_sha256"] == CATALOGUE_SHA256
  end

  def self.find(name:, city:, locale: I18n.locale)
    return unless name.is_a?(String) && name.present? && name.length <= 180 &&
      city.is_a?(String) && city.present? && city.length <= 100

    candidates = current_entries.fetch(normalize(name), [])
    candidates = legacy_entries.fetch(normalize(name), []) if candidates.empty?
    matches = candidates.select do |entry|
      variants = [ entry.fetch("city"), *CourtCatalogue::DATA.fetch("places").fetch(entry.fetch("city"), {}).values ]
      variants.any? { |value| normalize(value) == normalize(city) }
    end
    return unless matches.one?

    entry = matches.first
    address = full_address(entry) if available? && entry["hearing_verified"] != false
    Details.new(court_name: CourtCatalogue.court_name(entry, locale:), address:)
  end

  def self.current_entries
    @current_entries ||= label_entries(:current_labels)
  end

  def self.legacy_entries
    @legacy_entries ||= label_entries(:labels)
  end

  def self.label_entries(key)
    CourtCatalogue::DATA.fetch("courts").each_with_object({}) do |entry, result|
      CourtCatalogue.option_for(entry, locale: :en).fetch(key).each do |label|
        values = result[normalize(label)] ||= []
        values << entry unless values.include?(entry)
      end
    end
  end

  def self.full_address(entry)
    key = entry.values_at("source", "city", "hearing_address")
    records = DATA.fetch("records").select { |row| row.values_at("source", "city", "hearing_address") == key }
    return unless records.one? && records.first["status"] == "available"

    address = records.first["address"]
    address if address.is_a?(String) && address.present? && address.length <= 500 && !address.include?("@")
  end

  def self.normalize(value)
    I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]/, "")
  end

  private_class_method :current_entries, :legacy_entries, :label_entries, :full_address, :normalize
end
