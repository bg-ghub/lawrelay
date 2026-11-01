require "sqlite3"

module Travel
  # A local public-address index, never an external geocoder. Ambiguous matches
  # are refused; official address points take precedence over OSM buildings.
  class AddressIndex
    Point = Data.define(:latitude, :longitude)

    def initialize(path: ENV["LAWRELAY_OSM_INDEX_PATH"])
      @path = path.to_s
    end

    def available?
      return false unless @path.present? && File.file?(@path)
      stat = File.stat(@path)
      stamp = [ stat.size, stat.mtime.to_f, stat.ino ]
      return @available if @availability_stamp == stamp

      @availability_stamp = stamp
      @canonical_streets = {}
      SQLite3::Database.new(@path, readonly: true) do |database|
        database.busy_timeout = 100
        @metadata = database.execute("SELECT key, value FROM metadata").to_h
      end
      best_valid = sha256?(@metadata["best_source_sha256"]) && @metadata["best_number_key_format"] == "preserve-separators-v1"
      usable_addresses = best_valid || @metadata["osm_number_key_format"] == "preserve-separators-v1"
      @available = @metadata["schema_version"] == "1" && sha256?(@metadata["source_sha256"]) && usable_addresses &&
        (!@metadata.key?("best_source_sha256") || best_valid)
    rescue SQLite3::Exception, SystemCallError
      @available = false
    end

    def version
      return unless available?

      [ File.size(@path), File.mtime(@path).to_i ].join("-")
    end

    def source_sha256
      @metadata["source_sha256"] if available?
    end

    def best_available?
      available? && sha256?(@metadata["best_source_sha256"])
    end

    def address(value)
      return unless available? && (parts = address_parts(value))
      cities = city_aliases(parts.fetch(:city))
      sources = []
      sources << "best" if best_available?
      if @metadata["osm_exact_number_key_format"] == "preserve-separators-v1" && @metadata["osm_exact_source_sha256"] == @metadata["source_sha256"]
        sources << "osm_exact"
      end
      sources.concat(%w[node way]) if @metadata["osm_number_key_format"] == "preserve-separators-v1"
      return if sources.empty?

      canonical = canonical_street(parts, cities)

      sql = <<~SQL
        SELECT DISTINCT a.latitude, a.longitude, a.osm_type
        FROM addresses a JOIN street_aliases s ON s.street_key = a.street_key
        WHERE s.alias_key = ? AND a.number_key = ? AND a.postcode = ?
          AND (a.city_key = '' OR a.city_key IN (#{([ "?" ] * cities.length).join(',')}))
          AND a.osm_type IN (#{([ "?" ] * sources.length).join(',')})
          #{'AND a.street_key = ?' if canonical}
        ORDER BY CASE WHEN a.osm_type = 'best' THEN 0 ELSE 1 END
        LIMIT 8
      SQL
      bindings = [ parts.fetch(:street), parts.fetch(:number), parts.fetch(:postcode), *cities, *sources, *Array(canonical) ]
      point = query(sql, bindings, preferred_source: "best")
      if parts[:box].present?
        # Explicit bus/boîte notation already identifies the house separately;
        # an indexed unit can refine it without reinterpreting a house code.
        return official_unit(parts, cities) || point
      end
      return point if point
      # A literal slash house code has priority, including when its official
      # points are ambiguous. Only an absent literal code may be interpreted as
      # a unit, through the explicitly retained BeSt house/box relationship.
      return if rows_exist?(sql, bindings)

      official_unit(parts, cities) || official_range(parts, cities)
    rescue SQLite3::Exception, SystemCallError
      nil
    end

    # Establish a postal/municipality alias only through the same unique
    # official address point. No OSM fallback or geographical proximity test.
    def official_city_alias?(value, city:)
      return false unless best_available? && city.is_a?(String) && city.present? && city.length <= 100
      parts = address_parts(value)
      return false unless parts

      published = official_point(parts, city_aliases(parts.fetch(:city)))
      municipality = official_point(parts, city_aliases(city))
      !!(published && municipality && published == municipality)
    rescue SQLite3::Exception, SystemCallError
      false
    end

    def court(name:, city:)
      return unless available? && name.is_a?(String) && city.is_a?(String)
      return if name.blank? || name.length > 180 || city.blank? || city.length > 100

      names = [ normalize(name) ]
      # A catalogue label and a mapped court must describe the same place.
      # There is deliberately no fallback to a city's centre or nearest court.
      cities = city_aliases(city)
      options = (@court_options ||= CourtCatalogue.options(locale: :nl)).select do |court|
        court.fetch(:cities).any? { |place| cities.include?(normalize(place)) }
      end
      current = options.select { |court| court.fetch(:current_labels, []).any? { |label| normalize(label) == names.first } }
      if current.any?
        return if current.any? { |court| court[:hearing_verified] == false }
        names.concat(current.flat_map { |court| court.fetch(:current_labels) }.map { |label| normalize(label) })
      else
        legacy = options.select { |court| court.fetch(:labels).any? { |label| normalize(label) == names.first } }
        return if legacy.any? { |court| court[:hearing_verified] == false }
        names.concat(legacy.flat_map { |court| court.fetch(:labels) }.map { |label| normalize(label) })
      end
      names.uniq!
      bindings = [ *names, *cities ]
      return if court_blocked?(names, cities)

      query(<<~SQL, bindings, preferred_source: "official")
        SELECT DISTINCT latitude, longitude, osm_type FROM courts
        WHERE name_key IN (#{([ "?" ] * names.length).join(',')})
          AND city_key IN (#{([ "?" ] * cities.length).join(',')})
        ORDER BY CASE WHEN osm_type = 'official' THEN 0 ELSE 1 END
        LIMIT 8
      SQL
    rescue SQLite3::Exception, SystemCallError
      nil
    end

    private

    def address_parts(value)
      return unless value.is_a?(String) && value.length <= 500
      parts = value.squish.match(/\A(.+?)\s*,?\s+(\d{4})\s+([^\d].*)\z/)
      return unless parts

      street_number = parts[1].strip.sub(/[,\s]+\z/, "")
      street_number = street_number.sub(/(?<=\d)\s*\/\s*(?=(?:bus|bte|bo[iî]te|box)\b)/i, " ")
      # Floor information changes neither the entrance nor the house number.
      floor = /(?:\d+(?:er|e|ème|de|ste)?|premier|eerste)\s+(?:étage|verdieping)/i
      street_number = street_number.sub(/\s*\(\s*#{floor}\s*\)\z/i, "").sub(/\s+-\s+#{floor}\z/i, "")
      street_number = street_number.sub(/\s+n[°º]\s*(?=\d)/i, " ")
      box = street_number.match(/\s+(?:bus|bte|bo[iî]te|box)\s*([a-zA-Z0-9\/-]+)\z/i)
      street_number = street_number[0...box.begin(0)] if box
      compact_box = street_number.match(/\s+b(\d+[a-zA-Z]?)\z/i) unless box
      street_number = street_number[0...compact_box.begin(0)] if compact_box
      street = street_number.match(/\A(.+?)\s*,?\s+(\d+\s*[a-zA-Z]?(?:\s*\/\s*[a-zA-Z0-9]+|\s*-\s*\d+\s*[a-zA-Z]?)?)\z/)
      return unless street

      { street: normalize(street[1]), number: number_key(street[2]), postcode: parts[2],
        city: parts[3].sub(/,?\s+(?:Belgi[eë]|Belgique|Belgien|Belgium)\z/i, ""),
        box: (box || compact_box)&.captures&.first&.then { |value| number_key(value) } }
    end

    def official_point(parts, cities)
      canonical = canonical_street(parts, cities)
      sql = <<~SQL
        SELECT DISTINCT a.latitude, a.longitude, a.osm_type
        FROM addresses a JOIN street_aliases s ON s.street_key = a.street_key
        WHERE s.alias_key = ? AND a.number_key = ? AND a.postcode = ? AND a.osm_type = 'best'
          AND a.city_key IN (#{([ "?" ] * cities.length).join(',')})
          #{'AND a.street_key = ?' if canonical}
        LIMIT 8
      SQL
      bindings = [ parts.fetch(:street), parts.fetch(:number), parts.fetch(:postcode), *cities, *Array(canonical) ]
      point = query(sql, bindings, preferred_source: "best")
      return point if point
      return if rows_exist?(sql, bindings)

      official_unit(parts, cities)
    end

    def query(sql, bindings, preferred_source: nil)
      rows = nil
      SQLite3::Database.new(@path, readonly: true) do |database|
        database.busy_timeout = 100
        database.execute("PRAGMA query_only = ON")
        rows = database.execute(sql, bindings)
      end
      return unless rows&.any?
      preferred = rows.select { |row| row[2] == preferred_source } if preferred_source
      rows = preferred if preferred&.any?
      return unless rows.length < 8
      rows = rows.map { |row| row.first(2) }
      return unless rows.all? { |latitude, longitude| valid_point?(latitude, longitude) }
      first = rows.first
      # OSM can contain an address node and its building. Collapse only points
      # within about 20 metres, never two different premises on the same street.
      return unless rows.all? { |latitude, longitude| (latitude - first[0]).abs <= 0.00015 && (longitude - first[1]).abs <= 0.00025 }

      Point.new(latitude: first[0], longitude: first[1])
    end

    def rows_exist?(sql, bindings)
      found = false
      SQLite3::Database.new(@path, readonly: true) do |database|
        database.busy_timeout = 100
        found = database.get_first_value("SELECT EXISTS(SELECT 1 FROM (#{sql}))", bindings) == 1
      end
      found
    end

    def official_unit(parts, cities)
      return unless best_available? && @metadata["best_unit_source_sha256"] == @metadata["best_source_sha256"]
      number, box = parts.values_at(:number, :box)
      number, box = number.split("/", 2) if box.blank? && number.include?("/")
      return if box.blank?

      numeric_box = box.match?(/\A\d{1,9}\z/)
      box_clause = if numeric_box
        "(a.box_key = ? OR (length(a.box_key) BETWEEN 1 AND 9 AND a.box_key NOT GLOB '*[^0-9]*' AND CAST(a.box_key AS INTEGER) = ?))"
      else
        "a.box_key = ?"
      end
      boxes = numeric_box ? [ box, box.to_i ] : [ box ]
      canonical = canonical_street(parts, cities)

      query(<<~SQL, [ parts.fetch(:street), number, *boxes, parts.fetch(:postcode), *cities, *Array(canonical) ], preferred_source: "best")
        SELECT DISTINCT a.latitude, a.longitude, 'best'
        FROM best_units a JOIN street_aliases s ON s.street_key = a.street_key
        WHERE s.alias_key = ? AND a.number_key = ? AND #{box_clause} AND a.postcode = ?
          AND a.city_key IN (#{([ "?" ] * cities.length).join(',')})
          #{'AND a.street_key = ?' if canonical}
        LIMIT 8
      SQL
    end

    def official_range(parts, cities)
      return unless best_available? && parts[:box].blank?
      range = parts.fetch(:number).match(/\A(\d+[a-z]?)-(\d+[a-z]?)\z/)
      return unless range

      endpoints = range.captures.map { |number| official_point(parts.merge(number:), cities) }
      return unless endpoints.all?
      first, last = endpoints
      return unless (first.latitude - last.latitude).abs <= 0.00015 && (first.longitude - last.longitude).abs <= 0.00025

      # The result is one actual official premise point, never an interpolated
      # coordinate between different buildings or an assumed missing endpoint.
      first
    end

    # Street aliases are shared across the country. A historical OSM alias in
    # another town must not add a different official street's address points.
    # Scope the canonical name to the requested postcode/municipality, including
    # when that official street lacks the requested house number.
    def canonical_street(parts, cities)
      return unless best_available?
      key = [ parts.fetch(:street), parts.fetch(:postcode), cities ]
      return @canonical_streets[key] if @canonical_streets.key?(key)

      found = false
      SQLite3::Database.new(@path, readonly: true) do |database|
        database.busy_timeout = 100
        found = database.get_first_value(<<~SQL, [ parts.fetch(:street), parts.fetch(:postcode), *cities ]).present?
          SELECT 1 FROM addresses
          WHERE street_key = ? AND postcode = ? AND osm_type = 'best'
            AND city_key IN (#{([ "?" ] * cities.length).join(',')})
          LIMIT 1
        SQL
      end
      @canonical_streets[key] = found ? parts.fetch(:street) : nil
    end

    def court_blocked?(names, cities)
      blocked = false
      SQLite3::Database.new(@path, readonly: true) do |database|
        database.busy_timeout = 100
        return false unless database.get_first_value("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'court_sources'")

        statuses = database.execute(<<~SQL, [ *names, *cities ]).flatten
          SELECT status FROM court_sources
          WHERE name_key IN (#{([ "?" ] * names.length).join(',')})
            AND city_key IN (#{([ "?" ] * cities.length).join(',')})
        SQL
        blocked = statuses.any? { |status| !status.in?(%w[matched missing unavailable not_found]) }
      end
      blocked
    end

    def city_aliases(city)
      normalized = normalize(city)
      names = [ city ]
      CourtCatalogue::DATA.fetch("places").each do |name, translations|
        variants = [ name, *translations.values ]
        names.concat(variants) if variants.any? { |variant| normalize(variant) == normalized }
      end
      names.map { |name| normalize(name) }.uniq
    end

    def normalize(value)
      I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]/, "")
    end

    def number_key(value)
      value.to_s.downcase.gsub(/\s+/, "")
    end

    def sha256?(value)
      value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
    end

    def valid_point?(latitude, longitude)
      latitude.is_a?(Numeric) && longitude.is_a?(Numeric) &&
        latitude.finite? && longitude.finite? && latitude.between?(49.3, 51.7) && longitude.between?(2.3, 6.7)
    end
  end
end
