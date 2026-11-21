require "net/http"
require "nokogiri"
require "timeout"

module Directory
  class ProfilePage
    MAX_BODY_BYTES = 1.megabyte
    TIMEOUT_SECONDS = 15

    Response = Data.define(:uri, :code, :body) do
      def html? = code == "200" && body.is_a?(String) && body.present? && body.bytesize <= MAX_BODY_BYTES
      def missing? = code.in?(%w[404 410])
    end

    def self.resolve(url, allow_redirect: true, fetcher: nil)
      canonical = AdvocaatBeProfileLookup.canonical_profile_url(url)
      return unless canonical

      response = read(URI(canonical), fetcher)
      return response unless response.code.in?(%w[301 308])
      return unless allow_redirect

      location = response.body.to_s
      location = "https://www.advocaat.be#{location}" if location.start_with?("/") && !location.start_with?("//")
      target = AdvocaatBeProfileLookup.canonical_profile_url(location)
      return unless target && target != canonical

      read(URI(target), fetcher)
    end

    def self.main(body)
      return if body.match?(/<!\s*ENTITY\b|<!\s*DOCTYPE[^>]*\[/im)

      options = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::RECOVER
      mains = Nokogiri::HTML::Document.parse(body, nil, nil, options).css("main#main")
      mains.first if mains.one? && mains.first.css("h1").one?
    end

    def self.listed_email(main)
      main.css("a[href]").each do |link|
        address = link["href"][/\Amailto:([^?]+)/i, 1]&.strip&.downcase
        return address if address && address.length <= 254 && address.match?(URI::MailTo::EMAIL_REGEXP)
      end
      nil
    end

    def self.read(uri, fetcher)
      raw = fetcher ? fetcher.call(uri) : fetch(uri)
      # Existing profile importers can supply either HTML or an HTTP redirect.
      code, body = case raw
      when String then [ "200", raw ]
      when Net::HTTPRedirection then [ raw.code, raw["location"] ]
      when Array then raw if raw.size == 2
      end
      Response.new(uri:, code: code.to_s, body:)
    end
    private_class_method :read

    def self.request_for(uri)
      Net::HTTP::Get.new(uri.request_uri, "Accept" => "text/html, application/xhtml+xml", "Accept-Encoding" => "identity")
    end

    def self.fetch(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.verify_hostname = true
      http.open_timeout = 5
      http.read_timeout = 8
      http.write_timeout = 5
      http.max_retries = 0

      http.start do |client|
        client.request(request_for(uri)) do |response|
          # Return inside the block to keep Net::HTTP from draining rejected bodies.
          return [ response.code, response["location"] ] unless response.code == "200"
          return unless response["Content-Type"].to_s.strip.match?(%r{\A(?:text/html|application/xhtml\+xml)(?:\s*;|\z)}i)
          return if response["Content-Length"].to_i > MAX_BODY_BYTES

          body = +"".b
          response.read_body do |chunk|
            return if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

            body << chunk
          end
          return [ response.code, body ]
        end
      end
    end
    private_class_method :fetch
  end
end
