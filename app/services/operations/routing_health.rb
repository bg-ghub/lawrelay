require "digest"

module Operations
  class RoutingHealth
    CACHE_TTL = 60.seconds
    PROBE_ORIGIN = Travel::AddressIndex::Point.new(latitude: 50.85, longitude: 4.35)
    PROBE_DESTINATION = Travel::AddressIndex::Point.new(latitude: 50.9, longitude: 4.4)

    def self.healthy?(index: nil, router: nil, cache: Rails.cache,
      endpoint: ENV["LAWRELAY_OSRM_URL"], index_path: ENV["LAWRELAY_OSM_INDEX_PATH"])
      return true if endpoint.blank? && index_path.blank?

      fingerprint = Digest::SHA256.hexdigest([ endpoint, index_path ].map(&:to_s).join("\0"))
      cache.fetch("operations:routing-health:v1:#{fingerprint}", expires_in: CACHE_TTL) do
        next false if endpoint.blank? || index_path.blank?

        index ||= Travel::AddressIndex.new(path: index_path)
        router ||= Travel::Router.new(endpoint:)
        index.available? && router.available? && router.route(origin: PROBE_ORIGIN, destination: PROBE_DESTINATION).present?
      rescue StandardError => error
        failed_check(error)
      end
    rescue StandardError => error
      failed_check(error)
    end

    def self.failed_check(error)
      Rails.logger.error("Operational routing health check failed: #{error.class}")
      false
    end
    private_class_method :failed_check
  end
end
