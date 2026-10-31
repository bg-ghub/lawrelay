require "net/http"
require "nokogiri"

module Directory
  class SignupProfile
    class ResponseTooLarge < StandardError; end
    class RejectedResponse < StandardError; end
    Result = Data.define(:status, :profile_url, :name, :first_name, :last_name, :email_address, :profile_attributes) do
      def success? = status == :ok
    end

    MAX_BODY_BYTES = 1.megabyte

    def self.call(profile_url:, fetcher: nil)
      new(profile_url:, fetcher:).call
    end

    def initialize(profile_url:, fetcher: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @fetcher = fetcher || method(:fetch_html)
    end

    def call
      return failure(:invalid_url) unless @profile_url

      html = @fetcher.call(URI(@profile_url))
      return failure(:unavailable) if html.blank? || html.bytesize > MAX_BODY_BYTES

      main = Nokogiri::HTML(html).at_css("main#main")
      name = main&.at_css("h1")&.text&.squish
      return failure(:malformed) if name.blank? || name.length > 201

      email = main.css('a[href^="mailto:"]').filter_map { |link| email_from(link["href"]) }.first
      return failure(:email_missing) unless email

      first_name, last_name = name.split(/\s+/, 2)
      # This is an editable suggestion, not verified given/family-name evidence.
      # Keep unusual names manual rather than truncating the directory identity.
      first_name = "" if first_name.to_s.length > 100
      last_name = "" if last_name.to_s.length > 100
      Result.new(status: :ok, profile_url: @profile_url, name:, first_name: first_name.to_s,
        last_name: last_name.to_s, email_address: email, profile_attributes: ProfileImport.attributes_from(main))
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError,
      ResponseTooLarge, RejectedResponse
      failure(:unavailable)
    end

    private

    def email_from(href)
      email = href.to_s.delete_prefix("mailto:").split("?", 2).first.to_s.strip.downcase
      email if email.length <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)
    end

    def fetch_html(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 5
      http.read_timeout = 8
      http.max_retries = 0
      request = Net::HTTP::Get.new(uri.request_uri, "Accept" => "text/html")
      http.start do |client|
        body = nil
        client.request(request) do |response|
          raise RejectedResponse unless response.is_a?(Net::HTTPSuccess)
          raise RejectedResponse unless response["content-type"].to_s.downcase.include?("text/html")

          body = +"".b
          response.read_body do |chunk|
            raise ResponseTooLarge if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

            body << chunk
          end
        end
        body
      end
    end

    def failure(status)
      Result.new(status:, profile_url: @profile_url, name: nil, first_name: nil, last_name: nil,
        email_address: nil, profile_attributes: {})
    end
  end
end
