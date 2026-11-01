require "net/http"
require "json"
require "timeout"

module Travel
  class Router
    Route = Data.define(:distance_meters, :duration_seconds)
    ALLOWED_HOSTS = %w[routing lawrelay-routing localhost 127.0.0.1 ::1].freeze
    MAX_BODY_BYTES = 64.kilobytes

    def initialize(endpoint: ENV["LAWRELAY_OSRM_URL"])
      @endpoint = URI(endpoint.to_s)
    rescue URI::InvalidURIError
      @endpoint = nil
    end

    def available?
      @endpoint.is_a?(URI::HTTP) && ALLOWED_HOSTS.include?(@endpoint.host) &&
        @endpoint.userinfo.nil? && @endpoint.query.nil? && @endpoint.fragment.nil? && @endpoint.path.in?([ "", "/" ])
    end

    def route(origin:, destination:)
      return unless available?
      return unless [ origin, destination ].all? { |point| valid_point?(point) }

      uri = @endpoint.dup
      uri.path = "/route/v1/driving/#{origin.longitude},#{origin.latitude};#{destination.longitude},#{destination.latitude}"
      uri.query = "overview=false&steps=false&alternatives=false&radiuses=250%3B250"
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 1
      http.read_timeout = 2
      http.write_timeout = 1
      http.max_retries = 0
      body = +""
      Timeout.timeout(4) do
        http.start do |client|
          client.request(Net::HTTP::Get.new(uri.request_uri, "Accept" => "application/json")) do |response|
            return unless response.is_a?(Net::HTTPSuccess)

            response.read_body do |chunk|
              return if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

              body << chunk
            end
          end
        end
      end
      parse(body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, JSON::ParserError, TypeError, ArgumentError, Timeout::Error
      nil
    end

    private

    def parse(body)
      data = JSON.parse(body)
      return unless data.is_a?(Hash) && data["code"] == "Ok"
      routes = data["routes"]
      waypoints = data["waypoints"]
      return unless routes.is_a?(Array) && routes.one? && waypoints.is_a?(Array) && waypoints.length == 2
      return unless waypoints.all? { |point| point.is_a?(Hash) && bounded_number?(point["distance"], 250) }
      route = routes.first
      return unless route.is_a?(Hash) && bounded_number?(route["distance"], 1_000_000) && bounded_number?(route["duration"], 86_400)

      Route.new(distance_meters: route["distance"].round, duration_seconds: route["duration"].round)
    end

    def bounded_number?(value, maximum)
      value.is_a?(Numeric) && value.finite? && value.between?(0, maximum)
    end

    def valid_point?(point)
      point.respond_to?(:latitude) && point.respond_to?(:longitude) &&
        point.latitude.is_a?(Numeric) && point.longitude.is_a?(Numeric) &&
        point.latitude.finite? && point.longitude.finite? &&
        point.latitude.between?(49.3, 51.7) && point.longitude.between?(2.3, 6.7)
    end
  end
end
