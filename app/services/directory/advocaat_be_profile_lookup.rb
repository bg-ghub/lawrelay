require "net/http"
require "nokogiri"

module Directory
  class AdvocaatBeProfileLookup
    Result = Data.define(:status, :profile_id, :source_url, :name, :email, :checked_at) do
      def success? = status == :ok
    end

    UUID = "[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}"
    PATH = %r{\A/nl/zoek-een-advocaat/advocaat/(#{UUID})\z}i
    HOSTS = %w[advocaat.be www.advocaat.be].freeze
    MAX_BODY_BYTES = 1.megabyte

    def self.call(profile_url:, full_name:, fetcher: nil)
      new(profile_url:, full_name:, fetcher:).call
    end

    def self.canonical_profile_url(profile_url)
      uri = URI.parse(profile_url.to_s)
      return unless uri.is_a?(URI::HTTPS) && HOSTS.include?(uri.host&.downcase)
      return unless uri.port == 443 && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?

      match = PATH.match(uri.path)
      return unless match

      "https://www.advocaat.be#{uri.path}"
    rescue URI::InvalidURIError
      nil
    end

    def self.valid_profile_url?(profile_url)
      canonical_profile_url(profile_url).present?
    end

    def self.names_match?(directory_name, submitted_name)
      normalized_name(directory_name) == normalized_name(submitted_name) && normalized_name(directory_name).present?
    end

    def self.normalized_name(value)
      value.to_s.unicode_normalize(:nfkd).downcase.gsub(/[^[:alnum:]]/, "")
    end

    def initialize(profile_url:, full_name:, fetcher: nil)
      @profile_url = profile_url.to_s
      @full_name = full_name.to_s
      @fetcher = fetcher || method(:fetch_html)
    end

    def call
      uri, profile_id = canonical_uri
      return failure(:invalid_url) unless uri

      html = @fetcher.call(uri)
      return failure(:unavailable) if html.blank?

      main = Nokogiri::HTML(html).at_css("main#main")
      return failure(:malformed) unless main

      name = main.at_css("h1")&.text&.squish
      return failure(:name_mismatch) unless self.class.names_match?(name, @full_name)

      email = main.css('a[href^="mailto:"]').map { |link| mailto(link["href"]) }.compact.first
      return failure(:email_missing) unless email

      Result.new(status: :ok, profile_id:, source_url: uri.to_s, name:, email:, checked_at: Time.current)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError
      failure(:unavailable)
    rescue Nokogiri::XML::SyntaxError
      failure(:malformed)
    end

    private

    def canonical_uri
      canonical_url = self.class.canonical_profile_url(@profile_url)
      return unless canonical_url

      [ URI(canonical_url), PATH.match(URI(canonical_url).path)[1].downcase ]
    end

    def fetch_html(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 8
      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "text/html")
      http.start do |client|
        body = nil
        client.request(request) do |response|
          next unless response.is_a?(Net::HTTPSuccess)
          next unless response["content-type"].to_s.downcase.include?("text/html")

          body = +"".b
          too_large = false
          response.read_body do |chunk|
            if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
              too_large = true
              break
            end

            body << chunk
          end
          body = nil if too_large
        end
        body
      end
    end

    def mailto(href)
      address = href.to_s.delete_prefix("mailto:").split(/[?]/).first.to_s.strip.downcase
      address if address.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def failure(status)
      Result.new(status:, profile_id: nil, source_url: nil, name: nil, email: nil, checked_at: nil)
    end
  end
end
