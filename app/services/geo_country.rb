# frozen_string_literal: true

class GeoCountry
  DATABASE_PATH = "/var/lib/lawrelay-geoip/GeoLite2-City.mmdb"

  class << self
    def challenge_enabled?
      Rails.env.production? && ActiveModel::Type::Boolean.new.cast(ENV.fetch("GEO_CHALLENGE_ENABLED", "false"))
    end

    def country_for(ip)
      return unless ip.present?

      record = reader.lookup(ip)
      record.country.iso_code if record&.found?
    rescue StandardError => error
      Rails.logger.warn("GeoCountry lookup unavailable: #{error.class}")
      nil
    end

    private

    def reader
      path = ENV.fetch("GEOIP_DATABASE_PATH", DATABASE_PATH)
      mtime = File.mtime(path).to_f
      (@reader_lock ||= Mutex.new).synchronize do
        if @reader.nil? || @reader_path != path || @reader_mtime != mtime
          @reader = MaxMindDB.new(path, MaxMindDB::LOW_MEMORY_FILE_READER)
          @reader_path = path
          @reader_mtime = mtime
        end
        @reader
      end
    end
  end
end
