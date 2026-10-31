require "net/http"
require "nokogiri"
require "timeout"
require "uri"

module Directory
  # Reports public directory evidence without changing accounts or retaining
  # another copy of a lawyer's contact details.
  class StatusCheck
    Result = Data.define(:status, :checked_at)

    MAX_BODY_BYTES = 1.megabyte
    TIMEOUT_SECONDS = 15

    class ResponseTooLarge < StandardError; end
    private_constant :ResponseTooLarge

    def self.call(profile_url:, full_name:, expected_email: nil, transport: nil)
      new(profile_url:, full_name:, expected_email:, transport:).call
    end

    def initialize(profile_url:, full_name:, expected_email: nil, transport: nil)
      @profile_url = profile_url.to_s
      @full_name = full_name.to_s
      @expected_email = expected_email
      @transport = transport || method(:perform_request)
    end

    def call
      uri = canonical_uri
      return result(:unavailable) unless uri && @full_name.present?
      return result(:unavailable) if !@expected_email.nil? && !valid_email?(@expected_email.to_s.strip.downcase)

      Timeout.timeout(TIMEOUT_SECONDS) do
        response = @transport.call(uri, Net::HTTP::Get.new(uri.request_uri,
          "Accept" => "text/html, application/xhtml+xml", "Accept-Encoding" => "identity"))
        return result(:unavailable) unless response.is_a?(Array) && response.size == 2

        status, body = response
        return result(:not_listed) if [ 404, "404", 410, "410" ].include?(status)
        return result(:unavailable) unless [ 200, "200" ].include?(status) && body.is_a?(String)
        return result(:unavailable) if body.blank? || body.bytesize > MAX_BODY_BYTES

        parse(body)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error,
      SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError, ResponseTooLarge,
      Nokogiri::XML::SyntaxError, URI::InvalidURIError, ArgumentError, Encoding::CompatibilityError
      result(:unavailable)
    end

    private

    def canonical_uri
      canonical_url = AdvocaatBeProfileLookup.canonical_profile_url(@profile_url)
      return unless canonical_url

      original = URI(@profile_url)
      return unless original.userinfo.nil? && original.query.nil? && original.fragment.nil?

      URI(canonical_url)
    end

    def perform_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true
      http.open_timeout = 5
      http.read_timeout = 8
      http.write_timeout = 5
      http.max_retries = 0

      http.start do |client|
        client.request(request) do |response|
          # Returning from the response block also skips Net::HTTP's automatic
          # body drain for rejected responses. The session's ensure closes it.
          return [ response.code, nil ] unless response.code == "200"
          return [ response.code, nil ] unless response["Content-Type"].to_s.strip.match?(%r{\A(?:text/html|application/xhtml\+xml)(?:\s*;|\z)}i)
          raise ResponseTooLarge if response["Content-Length"].to_i > MAX_BODY_BYTES

          body = +"".b
          response.read_body do |chunk|
            raise ResponseTooLarge if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

            body << chunk
          end
          return [ response.code, body ]
        end
      end
    end

    def parse(body)
      return result(:unavailable) if body.match?(/<!\s*ENTITY\b|<!\s*DOCTYPE[^>]*\[/im)

      options = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::RECOVER
      document = Nokogiri::HTML::Document.parse(body, nil, nil, options)
      mains = document.css("main#main")
      return result(:unavailable) unless mains.size == 1

      headings = mains.first.css("h1")
      return result(:unavailable) unless headings.size == 1

      name = headings.first.text.squish
      return result(:unavailable) if name.blank?

      email = mains.first.css("a[href]").filter_map { |link| mailto(link["href"]) }.first
      return result(:unavailable) unless email
      return result(:changed) unless AdvocaatBeProfileLookup.names_match?(name, @full_name)
      return result(:changed) if !@expected_email.nil? && email != @expected_email.to_s.strip.downcase

      result(:active)
    end

    def mailto(href)
      return unless href.to_s.match?(/\Amailto:/i)

      address = href.sub(/\Amailto:/i, "").split("?", 2).first.to_s.strip.downcase
      address if valid_email?(address)
    end

    def valid_email?(address)
      address.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def result(status)
      Result.new(status:, checked_at: Time.current)
    end
  end
end
