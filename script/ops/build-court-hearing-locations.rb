require "digest"
require "json"
require "optparse"
require_relative "import-court-addresses"

# Public address facts for the website. This is an offline build: runtime court
# details need neither a routing engine nor a SQLite address index.
class CourtHearingLocationsBuilder
  MAX_BYTES = 8 * 1024 * 1024

  def initialize(sources_path:, overrides_path:, index_path:, catalogue: CourtCatalogue, index: nil)
    @sources_path, @overrides_path, @index_path = sources_path, overrides_path, index_path
    @catalogue = catalogue
    @index = index || Travel::AddressIndex.new(path: index_path)
  end

  def call
    raise ArgumentError, "A checked local address index is required" unless @index.available?

    collection, source_sha = read_json(@sources_path)
    overrides, overrides_sha = read_json(@overrides_path)
    unless collection["schema_version"] == 1 && collection["records"].is_a?(Hash) && overrides["records"].is_a?(Hash) &&
        overrides["reviewed_on"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise ArgumentError, "Unsupported public source records"
    end
    @records = collection.fetch("records").merge(overrides.fetch("records"))
    @reviewed_sources = overrides.fetch("records").keys

    locations = @catalogue::DATA.fetch("courts").map { |entry| location(entry) }
    keys = locations.map { |row| row.values_at("source", "city", "hearing_address") }
    raise ArgumentError, "Duplicate hearing-location selectors" unless keys.uniq.length == keys.length

    {
      schema_version: 1,
      reviewed_on: overrides.fetch("reviewed_on"),
      catalogue_hash_format: "parsed-json-v1",
      catalogue_sha256: Digest::SHA256.hexdigest(JSON.generate(@catalogue::DATA)),
      official_sources_sha256: source_sha,
      official_sources_updated_at: collection["updated_at"],
      reviewed_overrides_sha256: overrides_sha,
      official_address_index_sha256: Digest::SHA256.file(@index_path).hexdigest,
      selection_rule: "exact-source-city-qualified-hearing-address-v1",
      records: locations
    }
  end

  private

  def read_json(path)
    raise ArgumentError, "Public source file is too large" if File.size(path) > MAX_BYTES
    bytes = File.binread(path)
    value = JSON.parse(bytes)
    raise ArgumentError, "Public source JSON must be an object" unless value.is_a?(Hash)

    [ value, Digest::SHA256.hexdigest(bytes) ]
  end

  def location(entry)
    source = entry.fetch("source")
    row = entry.slice("source", "city", "hearing_address")
    row["hearing_source"] = entry["hearing_source"] if entry["hearing_source"]
    return row.merge("status" => "unconfirmed") if entry["hearing_verified"] == false
    record = @records[source]
    unless record.is_a?(Hash) && record["source_url"] == source && CourtAddressCollector.safe_url?(source) &&
        CourtAddressImporter.valid_final_url?(source, record["final_url"], reviewed: @reviewed_sources.include?(source)) && record["status"].in?(%w[ok ambiguous])
      return row.merge("status" => "unavailable")
    end
    values = record["addresses"]
    unless values.is_a?(Array) && values.any? && values.length <= 20 &&
        values.all? { |value| value.is_a?(String) && value.present? && value.length <= 500 && !value.include?("@") }
      return row.merge("status" => "unavailable")
    end
    return row.merge("status" => "ambiguous") if record["status"] == "ambiguous" && values.one?
    addresses = values.map { |value| CourtAddressImporter.parse_published_address(value) }
    return row.merge("status" => "unavailable") if addresses.any?(&:nil?)

    if @reviewed_sources.include?(source) && CourtAddressCollector::SPECIAL_URLS.include?(source)
      matching = addresses
    else
      cities = [ entry.fetch("city"), *@catalogue::DATA.fetch("places").fetch(entry.fetch("city"), {}).values ].map { |city| normalize(city) }.uniq
      matching = addresses.select do |address|
        cities.include?(normalize(address.city)) ||
          (address.municipality && cities.include?(normalize(address.municipality))) ||
          @index.official_city_alias?(address.value, city: entry.fetch("city"))
      end
      if entry["hearing_address"]
        matching.select! do |address|
          premise = address.value.match(/\A(.+?)\s*,?\s+[1-9]\d{3}\s/)&.captures&.first
          premise && normalize(premise) == normalize(entry.fetch("hearing_address"))
        end
      end
    end
    return row.merge("status" => "ambiguous") unless matching.one?

    address = matching.first.value
    # A single postal string can still identify two separate buildings. Keep
    # the combined Neufchâteau 1 et 7/1 location unresolved, rather than choosing
    # one entrance or representing a city-centre point as a full address.
    return row.merge("status" => "ambiguous") if address.match?(/\b\d+\s+et\s+\d+(?:\/\d+)?\b/i)

    row.merge("status" => "available", "address" => address.sub(/\s*,?\s+([1-9]\d{3}\s+[^\d].*)\z/, ', \1'),
      "source_url" => record.fetch("final_url"))
  end

  def normalize(value)
    I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]/, "")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby script/ops/build-court-hearing-locations.rb --sources OFFICIAL_JSON --overrides REVIEWED_JSON --index CHECKED_INDEX --output NEW_JSON"
    parser.on("--sources PATH") { |value| options[:sources_path] = value }
    parser.on("--overrides PATH") { |value| options[:overrides_path] = value }
    parser.on("--index PATH") { |value| options[:index_path] = value }
    parser.on("--output PATH") { |value| options[:output_path] = value }
  end.parse!
  abort "--sources, --overrides, --index and --output are required" unless %i[sources_path overrides_path index_path output_path].all? { |key| options[key] }
  output = options.delete(:output_path)
  abort "Output already exists; choose a new reviewed output path" if File.exist?(output)
  require_relative "../../config/environment"
  document = CourtHearingLocationsBuilder.new(**options).call
  File.write(output, JSON.pretty_generate(document) + "\n")
  puts JSON.generate(output:, counts: document.fetch(:records).map { |row| row.fetch("status") }.tally)
end
