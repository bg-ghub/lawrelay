require "net/http"
require "nokogiri"
require "timeout"
require "uri"

module BusinessRegistry
  # A deliberately narrow wrapper around CBE Public Search. It supports one
  # user-requested company lookup; it is not a directory importer.
  class PublicLookup
    Result = Data.define(:status, :attributes, :snapshot_date) do
      def success?
        status == :ok
      end
    end

    ENDPOINT = URI("https://kbopub.economie.fgov.be/kbopub/toonondernemingps.html").freeze
    MAX_BODY_BYTES = 1.megabyte
    TIMEOUT_SECONDS = 15

    class ResponseTooLarge < StandardError; end

    def self.configured?
      true
    end

    def self.call(enterprise_number:, locale:, transport: nil)
      new(enterprise_number:, locale:, transport:).call
    end

    def initialize(enterprise_number:, locale:, transport: nil)
      @enterprise_number = Firm.normalize_enterprise_number(enterprise_number)
      @locale = locale # Kept in the interface; Public Search is requested in its stable NL shape.
      @transport = transport || method(:perform_request)
    end

    def call
      return result(:invalid) unless Firm.valid_enterprise_number?(@enterprise_number)

      status, body = @transport.call(endpoint_uri, request_for(endpoint_uri))
      return result(:not_found) if status.to_i == 404
      return result(:unavailable) unless status.to_i == 200 && body.is_a?(String) && body.bytesize <= MAX_BODY_BYTES

      parse(body)
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error,
      SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError, ResponseTooLarge,
      Nokogiri::XML::SyntaxError, Date::Error, URI::InvalidURIError
      result(:unavailable)
    end

    private

    def endpoint_uri
      URI::HTTPS.build(host: ENDPOINT.host, path: ENDPOINT.path,
        query: URI.encode_www_form(ondernemingsnummer: @enterprise_number, lang: "nl"))
    end

    def request_for(uri)
      Net::HTTP::Get.new(uri).tap do |request|
        request["Accept"] = "text/html, application/xhtml+xml"
      end
    end

    # Kept as a small private seam for offline tests. Redirects, non-HTML
    # responses and oversize bodies are deliberately not followed or parsed.
    def perform_request(uri, request)
      Timeout.timeout(TIMEOUT_SECONDS) do
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.open_timeout = 5
        http.read_timeout = 8
        http.write_timeout = 5
        http.max_retries = 0

        http.start do |client|
          client.request(request) do |response|
            return [ response.code, nil ] unless response.code.to_i == 200
            return [ response.code, nil ] unless response["Content-Type"].to_s.match?(%r{\A(?:text/html|application/xhtml\+xml)\b}i)

            body = +"".b
            response.read_body do |chunk|
              raise ResponseTooLarge if body.bytesize + chunk.bytesize > MAX_BODY_BYTES

              body << chunk
            end
            return [ response.code, body ]
          end
        end
      end
    end

    def parse(body)
      # Public Search is XHTML and begins with a normal DOCTYPE. Internal DTDs
      # and entity declarations are not needed for the fields we read.
      return result(:unavailable) if body.match?(/<!\s*ENTITY\b|<!\s*DOCTYPE[^>]*\[/im)

      options = Nokogiri::XML::ParseOptions::NONET | Nokogiri::XML::ParseOptions::RECOVER
      document = Nokogiri::HTML::Document.parse(body, nil, nil, options)
      return result(:unavailable) unless normalized(document.at_css("title")&.text).start_with?("Gegevens van de geregistreerde entiteit")
      number = value_for(document, "Ondernemingsnummer")
      return result(:not_found) unless Firm.normalize_enterprise_number(number) == @enterprise_number
      return result(:not_found) unless active?(document)

      name = RegisteredName.call(name: value_for(document, "Naam"),
        legal_form: value_for(document, "Rechtsvorm"), entity_type: value_for(document, "Type entiteit"))
      return result(:unavailable) unless valid_length?(name, 160)

      attributes = { name:, enterprise_number: @enterprise_number }.merge(registered_office(document))
      date = snapshot_date(document)
      return result(:unavailable) unless date

      Result.new(status: :ok, attributes:, snapshot_date: date)
    end

    def active?(document)
      row = row_for(document, "Status")
      row && normalized(row.xpath("./td").last.at_css("span.pageactief")&.text) == "Actief"
    end

    def registered_office(document)
      # The official company page renders the registered office as one labelled
      # cell in its main facts table, unlike establishment addresses elsewhere.
      lines = value_lines_for(document, "Adres van de zetel")
      return {} unless lines.length.in?(2..3)

      match = lines.second.match(/\A(\d{4})\s+(.+)\z/)
      return {} unless match
      return {} if lines.third.present? && !belgian_country?(lines.third)

      address = lines.first
      postal_code = match[1]
      city = match[2]
      return {} unless valid_length?(address, 200) && valid_length?(postal_code, 12) && valid_length?(city, 100)

      { address_line_1: address, postal_code:, city: }
    end

    def belgian_country?(value)
      %w[België Belgique Belgien Belgium].any? { |country| normalized(value).casecmp?(country) }
    end

    def snapshot_date(document)
      match = document.text.match(/Toestand\s+in\s+de\s+KBO\s+databank\s+op\s+(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{4})/i)
      return unless match

      Date.new(match[3].to_i, match[2].to_i, match[1].to_i)
    end

    def value_for(scope, label)
      row = row_for(scope, label)
      value_lines(row).join(" ").presence
    end

    def value_lines_for(scope, label)
      value_lines(row_for(scope, label))
    end

    def value_lines(row)
      cell = row&.xpath("./td")&.last
      return [] unless cell

      copy = cell.dup
      copy.xpath(".//*[contains(concat(' ', normalize-space(@class), ' '), ' upd ')]").remove
      copy.xpath(".//br").each { |line_break| line_break.replace("\n") }
      copy.text.split(/\r?\n/).map { |line| normalized(line) }.reject(&:blank?)
    end

    def row_for(scope, label)
      scope.xpath(".//tr").find do |row|
        cells = row.xpath("./td")
        cells.length >= 2 && fact_row?(cells) &&
          normalized(cells.first.text).delete_suffix(":").casecmp?(label)
      end
    end

    def fact_row?(cells)
      classes = cells.first["class"].to_s.split & cells.last["class"].to_s.split
      classes.intersect?(%w[QL RL])
    end

    def valid_length?(value, maximum)
      value.present? && value.length <= maximum
    end

    def normalized(value)
      value.to_s.squish
    end

    def result(status)
      Result.new(status:, attributes: {}, snapshot_date: nil)
    end
  end
end
