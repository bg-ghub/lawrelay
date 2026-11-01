require "digest"
require "net/http"
require "nokogiri"
require "timeout"

module Directory
  class AdvocaatBeNameSearch
    class RejectedResponse < StandardError; end
    class ResponseTooLarge < StandardError; end
    Result = Data.define(:status, :candidates, :truncated) do
      def success? = status == :ok
    end

    SEARCH_URL = "https://www.advocaat.be/nl/zoek-een-advocaat".freeze
    MAX_BODY_BYTES = 1.megabyte
    MAX_RESULTS = 8
    CACHE_LIFETIME = 10.minutes

    def self.normalized_query(value)
      return unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 400

      query = value.unicode_normalize(:nfkc).squish
      return unless query.length.between?(3, 100) && query.scan(/\p{L}/).length >= 2
      return unless query.match?(/\A[\p{L}\p{M} .’'\-]+\z/)

      query
    end

    def self.call(name_query:, fetcher: nil, cache: Rails.cache)
      new(name_query:, fetcher:, cache:).call
    end

    def initialize(name_query:, fetcher: nil, cache: Rails.cache)
      @query = self.class.normalized_query(name_query)
      @fetcher = fetcher || method(:fetch_html)
      @cache = cache
    end

    def call
      return failure(:invalid_query) unless @query

      cached = @cache&.read(cache_key)
      return result(cached) if valid_payload?(cached)

      uri = URI(SEARCH_URL)
      uri.query = URI.encode_www_form(theme: "", radius: "", name: @query, languages: "", diplomas: "")
      html = @fetcher.call(uri)
      return failure(:unavailable) unless html.is_a?(String) && html.present? && html.bytesize <= MAX_BODY_BYTES

      main = Nokogiri::HTML(html).at_css("main#main")
      return failure(:unavailable) unless main&.at_css('input[name="name"]')

      candidates = main.css(".card h3 a").filter_map { |link| candidate_from(link) }.uniq { |item| item.fetch("profile_url") }
      payload = { "candidates" => candidates.first(MAX_RESULTS), "truncated" => candidates.length > MAX_RESULTS }
      @cache&.write(cache_key, payload, expires_in: CACHE_LIFETIME)
      result(payload)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError,
      Timeout::Error, RejectedResponse, ResponseTooLarge, ActiveRecord::ActiveRecordError
      failure(:unavailable)
    end

    private

    def candidate_from(link)
      href = link["href"].to_s
      url = AdvocaatBeProfileLookup.canonical_profile_url(href.start_with?("/") && !href.start_with?("//") ? "https://www.advocaat.be#{href}" : href)
      name = link.text.squish
      return unless url && name.present? && name.length <= 201 && name.match?(/\p{L}/) && !name.include?("@")

      card = link.ancestors.find { |node| node["class"].to_s.split.include?("card") }
      lines = card&.at_css("address")&.xpath(".//text()")&.map { |node| node.text.squish }&.reject(&:blank?)
      location = lines&.last
      location = nil unless location.is_a?(String) && location.present? && location.length <= 160 && !location.include?("@")
      { "name" => name, "profile_url" => url, "location" => location }
    end

    def valid_payload?(payload)
      payload.is_a?(Hash) && payload.keys.sort == %w[candidates truncated] &&
        [ true, false ].include?(payload["truncated"]) && payload["candidates"].is_a?(Array) &&
        payload["candidates"].size <= MAX_RESULTS && payload["candidates"].all? do |item|
          item.is_a?(Hash) && item.keys.sort == %w[location name profile_url] &&
            item["name"].is_a?(String) && item["name"].present? && item["name"].length <= 201 && !item["name"].include?("@") &&
            item["profile_url"].is_a?(String) && item["profile_url"].present? &&
            AdvocaatBeProfileLookup.canonical_profile_url(item["profile_url"]) == item["profile_url"] &&
            (item["location"].nil? || (item["location"].is_a?(String) && item["location"].length <= 160 && !item["location"].include?("@")))
        end
    end

    def result(payload)
      Result.new(status: :ok, candidates: payload.fetch("candidates").deep_dup, truncated: payload.fetch("truncated"))
    end

    def failure(status)
      Result.new(status:, candidates: [], truncated: false)
    end

    def cache_key
      "directory-name-search:v1:#{Digest::SHA256.hexdigest(@query.downcase)}"
    end

    def fetch_html(uri)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 8
      http.write_timeout = 5
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "text/html")
      Timeout.timeout(15) do
        http.start do |client|
          body = +"".b
          client.request(request) do |response|
            raise RejectedResponse unless response.is_a?(Net::HTTPSuccess) && response["content-type"].to_s.downcase.include?("text/html")

            response.read_body do |chunk|
              raise ResponseTooLarge if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

              body << chunk
            end
          end
          body
        end
      end
    end
  end
end
