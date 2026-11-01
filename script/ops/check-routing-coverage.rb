abort "Set LAWRELAY_OSM_INDEX_PATH to the prepared local index." if ENV["LAWRELAY_OSM_INDEX_PATH"].blank?
index = Travel::AddressIndex.new
abort "Local OSM address index is unavailable." unless index.available?

options = CourtCatalogue.options(locale: :nl)
matched = options.count do |court|
  index.court(name: court.fetch(:label), city: court.fetch(:city))
end
puts({ courts: options.length, mapped_courts: matched, unmapped_courts: options.length - matched }.to_json)
