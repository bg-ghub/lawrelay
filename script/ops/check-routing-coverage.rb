abort "Set LAWRELAY_OSM_INDEX_PATH to the prepared local index." if ENV["LAWRELAY_OSM_INDEX_PATH"].blank?
index = Travel::AddressIndex.new
abort "Local OSM address index is unavailable." unless index.available?

options = CourtCatalogue.options(locale: :nl)
matched = options.count do |court|
  court.fetch(:labels).any? do |label|
    court.fetch(:cities).any? { |city| index.court(name: label, city:) }
  end
end
puts({ courts: options.length, mapped_courts: matched, unmapped_courts: options.length - matched }.to_json)
