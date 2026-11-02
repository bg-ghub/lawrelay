require "digest"
require "fileutils"
require "json"
require "optparse"
require "sqlite3"
require "tempfile"
require "uri"
require_relative "collect-court-addresses"

# Offline enrichment only: match a catalogue entry to its exact, previously
# collected official source, then resolve its single address in the local index.
# No public geocoder, page request, nearest-court guess or input mutation occurs.
class CourtAddressImporter
  MAX_SOURCE_BYTES = 8 * 1024 * 1024
  REVIEWED_DESTINATION_HOSTS = %w[st.vith.be www.st.vith.be].freeze
  OFFICIAL_COORDINATE_HOSTS = %w[ciney.be www.ciney.be].freeze
  PublishedAddress = Data.define(:value, :city, :municipality)

  def self.parse_published_address(address)
    return unless address.is_a?(String)
    match = address.squish.match(/\A.+?\s*,?\s+[1-9]\d{3}\s+([^\d].*)\z/)
    return unless match

    city = match[1].sub(/,?\s+(?:Belgi[eë]|Belgique|Belgien|Belgium)\z/i, "").strip
    municipality = nil
    if (qualified = city.match(/\A([\p{L}\p{M}'’ .-]+?)\s*\(([\p{L}\p{M}'’ .-]+)\)\z/u))
      city = qualified[1].strip
      municipality = qualified[2].strip
    end
    return unless city.match?(/\A[\p{L}\p{M}'’ .-]+\z/u)

    value = address.squish.sub(/#{Regexp.escape(match[1])}\z/, city)
    PublishedAddress.new(value:, city:, municipality:)
  end

  def self.valid_final_url?(source, final_url, reviewed: false)
    return true if CourtAddressCollector.safe_url?(final_url)
    return false unless reviewed && final_url.is_a?(String)

    uri = URI(final_url)
    original = URI(source)
    approved_host = uri.host == original.host || REVIEWED_DESTINATION_HOSTS.include?(uri.host)
    uri.is_a?(URI::HTTPS) && uri.port == 443 && approved_host && uri.userinfo.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def initialize(input_path:, output_path:, sources_path:, catalogue: CourtCatalogue,
    overrides_path: Rails.root.join("config/court_address_overrides.be.json"))
    @input_path = File.expand_path(input_path)
    @output_path = File.expand_path(output_path)
    @sources_path = File.expand_path(sources_path)
    @catalogue = catalogue
    @overrides_path = overrides_path && File.expand_path(overrides_path)
  end

  def call
    raise ArgumentError, "Input and output must be different files" if @input_path == @output_path
    raise ArgumentError, "Output already exists; choose a new completed index path" if File.exist?(@output_path)
    raise ArgumentError, "A complete local address index is required" unless Travel::AddressIndex.new(path: @input_path).available?
    raise ArgumentError, "Official source collection is too large" if File.size(@sources_path) > MAX_SOURCE_BYTES

    source_bytes = File.binread(@sources_path)
    @collection = JSON.parse(source_bytes)
    unless @collection.is_a?(Hash) && @collection["schema_version"] == 1 && @collection["records"].is_a?(Hash)
      raise ArgumentError, "Unsupported official source collection"
    end
    @collection_sha = Digest::SHA256.hexdigest(source_bytes)
    @records = @collection.fetch("records").dup
    apply_reviewed_overrides
    @input_sha = Digest::SHA256.file(@input_path).hexdigest
    @index = Travel::AddressIndex.new(path: @input_path)
    counts = Hash.new(0)

    temporary = Tempfile.new([ "court-addresses-", ".sqlite3" ], File.dirname(@output_path))
    temporary.close
    begin
      FileUtils.cp(@input_path, temporary.path)
      SQLite3::Database.new(temporary.path) do |database|
        database.busy_timeout = 1_000
        database.execute("PRAGMA journal_mode = DELETE")
        database.transaction do
          database.execute("DELETE FROM courts WHERE osm_type = 'official'")
          database.execute("DROP TABLE IF EXISTS court_sources")
          database.execute(<<~SQL)
            CREATE TABLE court_sources (
              name_key TEXT NOT NULL, city_key TEXT NOT NULL, source_url TEXT NOT NULL,
              status TEXT NOT NULL, source_sha256 TEXT NOT NULL,
              PRIMARY KEY (name_key, city_key, source_url)
            ) WITHOUT ROWID
          SQL
          @catalogue::DATA.fetch("courts").each_with_index do |entry, index|
            status = import_entry(database, entry, index)
            counts[status] += 1
          end
          metadata = {
            "official_court_sources_sha256" => @collection_sha,
            "official_court_sources_updated_at" => @collection["updated_at"].to_s,
            "official_court_base_index_sha256" => @input_sha,
            "official_court_address_rule" => "exact-source-qualified-hearing-address-v4"
          }
          if @overrides_sha
            metadata["official_court_overrides_sha256"] = @overrides_sha
            metadata["official_court_overrides_reviewed_on"] = @overrides_reviewed_on
          end
          metadata.each do |key, value|
            database.execute("DELETE FROM metadata WHERE key = ?", [ key ])
            database.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", [ key, value ])
          end
        end
        raise "Completed court index failed integrity check" unless database.get_first_value("PRAGMA integrity_check") == "ok"
        database.execute("PRAGMA optimize")
      end
      raise "Completed court index failed readiness" unless Travel::AddressIndex.new(path: temporary.path).available?

      File.rename(temporary.path, @output_path)
      { court_entries: @catalogue::DATA.fetch("courts").length, counts:, source_sha256: @collection_sha,
        overrides_sha256: @overrides_sha, input_sha256: @input_sha, output_sha256: Digest::SHA256.file(@output_path).hexdigest }
    ensure
      temporary.close!
    end
  end

  private

  def import_entry(database, entry, index)
    source = entry.fetch("source")
    record = @records[source]
    option = if @catalogue.respond_to?(:option_for)
      @catalogue.option_for(entry, locale: :nl)
    else
      { labels: @catalogue::LOCALES.map { |locale| @catalogue.send(:label, entry, locale) }.uniq,
        cities: [ entry.fetch("city"), *@catalogue::DATA.fetch("places").fetch(entry.fetch("city"), {}).values ].uniq,
        hearing_verified: entry["hearing_verified"] != false }
    end
    status, point = option[:hearing_verified] == false ? [ "unconfirmed", nil ] : resolve(source, record, entry)
    selected = record.is_a?(Hash) ? record.slice("source_url", "final_url", "status", "addresses", "fetched_at", "address_role", "reviewed_point", "reviewed_points") : { "source_url" => source, "status" => "missing" }
    selected["venue_city"] = entry.fetch("city")
    selected["hearing_address"] = entry["hearing_address"]
    selected["hearing_verified"] = option[:hearing_verified] != false
    source_sha = Digest::SHA256.hexdigest(JSON.generate(selected))
    labels = option.fetch(:labels)
    cities = option.fetch(:cities)
    source_id = Digest::SHA256.hexdigest([ source, index ].join("\0")).first(15).to_i(16)
    labels.each do |label|
      cities.each do |city|
        name_key = normalize(label)
        city_key = normalize(city)
        database.execute("INSERT OR REPLACE INTO court_sources VALUES (?, ?, ?, ?, ?)", [ name_key, city_key, source, status, source_sha ])
        if point
          database.execute("INSERT INTO courts (name_key, city_key, latitude, longitude, osm_type, osm_id, name) VALUES (?, ?, ?, ?, 'official', ?, ?)",
            [ name_key, city_key, point.latitude, point.longitude, source_id, label ])
        end
      end
    end
    status
  end

  def resolve(source, record, entry)
    return [ "missing", nil ] unless record
    return [ "invalid", nil ] unless record.is_a?(Hash) && record["source_url"] == source && CourtAddressCollector.safe_url?(source)
    return [ "venue_mismatch", nil ] if record["status"] == "venue_mismatch"
    return [ "not_found", nil ] if record["status"] == "not_found"
    return [ "unavailable", nil ] unless record["status"].in?(%w[ok ambiguous])
    return [ "invalid", nil ] unless valid_final_url?(source, record["final_url"])

    addresses = record["addresses"]
    return [ "invalid", nil ] unless addresses.is_a?(Array) && addresses.all? { |address| address.is_a?(String) && address.present? && address.length <= 500 && !address.include?("@") }
    return [ "ambiguous", nil ] if addresses.empty? || (record["status"] == "ambiguous" && addresses.one?)
    if @verified_overrides.include?(source) && CourtAddressCollector::SPECIAL_URLS.include?(source)
      return [ "ambiguous", nil ] unless addresses.one?
      selected_address = published_address(addresses.first)
      return [ "invalid", nil ] unless selected_address
    else
      cities = [ entry.fetch("city"), *@catalogue::DATA.fetch("places").fetch(entry.fetch("city"), {}).values ].map { |city| normalize(city) }.uniq
      published = addresses.map { |address| published_address(address) }
      return [ "invalid", nil ] if published.any?(&:nil?)
      matching = published.select do |address|
        cities.include?(normalize(address.city)) ||
          (address.municipality && cities.include?(normalize(address.municipality))) ||
          @index.official_city_alias?(address.value, city: entry.fetch("city"))
      end
      if entry["hearing_address"]
        expected = entry["hearing_address"]
        return [ "invalid", nil ] unless expected.is_a?(String) && expected.present? && expected.length <= 200

        matching.select! do |address|
          premise = address.value.match(/\A(.+?)\s*,?\s+[1-9]\d{3}\s/)&.captures&.first
          premise && normalize(premise) == normalize(expected)
        end
      end
      return [ "venue_mismatch", nil ] if matching.empty?
      return [ "ambiguous", nil ] unless matching.one?
      selected_address = matching.first
    end

    candidates = [ selected_address.value ]
    if selected_address.municipality
      candidates << selected_address.value.sub(/#{Regexp.escape(selected_address.city)}\z/, selected_address.municipality)
    end
    points = candidates.filter_map { |address| @index.address(address) }.uniq
    point = points.first if points.one?
    if record.key?("reviewed_point") || record.key?("reviewed_points")
      reviewed = selected_reviewed_point(source, record, addresses, selected_address)
      return [ "invalid", nil ] if reviewed == :invalid
      point ||= reviewed if points.empty?
    end
    point ? [ "matched", point ] : [ "unmapped", nil ]
  end

  def selected_reviewed_point(source, record, addresses, selected_address)
    return :invalid if record.key?("reviewed_point") && record.key?("reviewed_points")
    if record.key?("reviewed_point")
      # A single point must never silently apply to multiple hearing buildings.
      return :invalid unless addresses.one?

      return reviewed_point(source, record.fetch("reviewed_point"), record:, address: addresses.first) || :invalid
    end

    values = record.fetch("reviewed_points")
    return :invalid unless values.is_a?(Array) && values.any? && values.length <= addresses.length
    return :invalid unless values.all? { |value| value.is_a?(Hash) && addresses.include?(value["address"]) }
    return :invalid unless values.map { |value| value["address"] }.uniq.length == values.length

    mapped = {}
    values.each do |value|
      point = reviewed_point(source, value, record:, address: value.fetch("address"))
      return :invalid unless point
      mapped[value.fetch("address")] = point
    end
    original = addresses.find { |address| published_address(address) == selected_address }
    mapped[original]
  end

  def reviewed_point(source, value, record:, address:)
    return unless @verified_overrides.include?(source) && value.is_a?(Hash)
    if value["kind"] == "official_published_point"
      return unless official_published_point?(value, record:, address:)
    else
      return unless value["pbf_sha256"] == @index.source_sha256 && value["osm_type"].in?(%w[node way relation])
      return unless value["osm_id"].is_a?(Integer) && value["osm_id"].positive? && value["osm_id"] < 2**63
      if value["osm_type"] == "relation"
        return unless value["geometry_complete"] == true && value["geometry_valid"] == true && value["point_in_building_geometry"] == true &&
          value["geometry_method"] == "multipolygon_interior_point" &&
          value["geometry_sha256"].is_a?(String) && value["geometry_sha256"].match?(/\A[0-9a-f]{64}\z/)
      end
    end

    latitude, longitude = value.values_at("latitude", "longitude")
    return unless [ latitude, longitude ].all? { |number| number.is_a?(Numeric) && number.finite? }
    return unless latitude.between?(49.3, 51.7) && longitude.between?(2.3, 6.7)

    Travel::AddressIndex::Point.new(latitude:, longitude:)
  end

  def official_published_point?(value, record:, address:)
    return false unless value["address"] == address
    return false unless value["coordinate_source_sha256"].is_a?(String) && value["coordinate_source_sha256"].match?(/\A[0-9a-f]{64}\z/)

    source_url = value["coordinate_source_url"]
    return false unless source_url.is_a?(String) && record["evidence_urls"].is_a?(Array) && record["evidence_urls"].include?(source_url)

    uri = URI(source_url)
    uri.is_a?(URI::HTTPS) && uri.port == 443 && OFFICIAL_COORDINATE_HOSTS.include?(uri.host) && uri.userinfo.nil? && uri.fragment.nil?
  rescue URI::InvalidURIError
    false
  end

  def normalize(value)
    I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]/, "")
  end

  def published_address(address)
    self.class.parse_published_address(address)
  end

  def apply_reviewed_overrides
    @verified_overrides = []
    return unless @overrides_path && File.file?(@overrides_path)
    raise ArgumentError, "Court overrides are too large" if File.size(@overrides_path) > MAX_SOURCE_BYTES

    bytes = File.binread(@overrides_path)
    overrides = JSON.parse(bytes)
    unless overrides.is_a?(Hash) && overrides["records"].is_a?(Hash) && overrides["reviewed_on"].to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      raise ArgumentError, "Court overrides need records and a review date"
    end
    sources = @catalogue::DATA.fetch("courts").map { |entry| entry.fetch("source") }
    overrides.fetch("records").each do |source, record|
      next unless sources.include?(source)

      @records[source] = record
      @verified_overrides << source
    end
    if @verified_overrides.any?
      @overrides_sha = Digest::SHA256.hexdigest(bytes)
      @overrides_reviewed_on = overrides["reviewed_on"]
    end
  end

  def valid_final_url?(source, final_url)
    self.class.valid_final_url?(source, final_url, reviewed: @verified_overrides.include?(source))
  end
end

if $PROGRAM_NAME == __FILE__
  options = {}
  OptionParser.new do |parser|
    parser.banner = "Usage: ruby script/ops/import-court-addresses.rb --input ADDRESS_INDEX --sources OFFICIAL_JSON --output NEW_INDEX"
    parser.on("--input PATH") { |value| options[:input_path] = value }
    parser.on("--sources PATH") { |value| options[:sources_path] = value }
    parser.on("--output PATH") { |value| options[:output_path] = value }
  end.parse!
  abort "--input, --sources and --output are required" unless %i[input_path sources_path output_path].all? { |key| options[key] }
  require_relative "../../config/environment"
  puts JSON.generate(CourtAddressImporter.new(**options).call)
end
