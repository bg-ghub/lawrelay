require "net/http"
require "nokogiri"
require "timeout"

module Directory
  class ProfileImport
    class ResponseTooLarge < StandardError; end
    Result = Data.define(:status, :profile_attributes) do
      def success? = status == :ok
    end

    MAX_BODY_BYTES = 1.megabyte
    TIMEOUT_SECONDS = 15
    LANGUAGE_CODES = { "nederlands" => "NL", "frans" => "FR", "duits" => "DE", "engels" => "EN" }.freeze
    PRACTICE_LABELS = %w[voorkeurmateries rechtsdomeinen vakgebieden].freeze
    BAR_LABELS = %w[balies balie barreaux barreau anwaltskammer anwaltskammern bars].freeze
    LOCATION_FIELDS = %i[directory_professional_address directory_bar_name].freeze

    def self.call(profile_url:, full_name:, fetcher: nil)
      new(profile_url:, full_name:, fetcher:).call
    end

    def self.attributes_from(main)
      profile = {}
      languages = labelled_values(main, %w[talen]).map { |value| LANGUAGE_CODES.fetch(value.downcase, value) }
      profile[:spoken_languages] = languages if languages.any?
      areas = labelled_values(main, PRACTICE_LABELS)
      profile[:practice_areas] = areas if areas.any?
      profile[:directory_bar_name] = labelled_value(main, BAR_LABELS)
      profile[:directory_professional_address] = professional_address(main)
      profile
    end

    def self.labelled_values(main, labels)
      heading = main.css("h2, h3").find { |element| labels.include?(element.text.squish.downcase) }
      content = heading&.next_element
      return [] unless content && content.name.in?(%w[p ul ol])

      values = content.name == "p" ? content.text.split(/[,;\n]/) : content.css("li").map(&:text)
      values.map { |value| value.squish.first(100) }.reject(&:blank?).uniq.first(20)
    end
    private_class_method :labelled_values

    def self.labelled_value(main, labels)
      heading = main.css("h2, h3").find { |element| labels.include?(element.text.squish.downcase) }
      value = heading&.next_element
      return unless value && value.name.in?(%w[p ul ol])

      text = value.name == "p" ? value.text : value.css("li").map(&:text).join(", ")
      text.squish.first(200).presence
    end
    private_class_method :labelled_value

    def self.professional_address(main)
      address = main.css("address").find { |element| element.text.squish.present? }
      return unless address

      # Preserve the separator in directory markup such as `Street 10<br>1000 City`.
      address = address.dup
      address.css("br").each { |break_node| break_node.replace("\n") }
      address.text.squish.first(500).presence
    end
    private_class_method :professional_address

    def initialize(profile_url:, full_name:, fetcher: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @full_name = full_name
      @fetcher = fetcher || method(:fetch_html)
    end

    def call
      return failure(:missing_profile) unless @profile_url

      html = Timeout.timeout(TIMEOUT_SECONDS) { @fetcher.call(URI(@profile_url)) }
      return failure(:unavailable) if html.blank? || html.bytesize > MAX_BODY_BYTES

      main = Nokogiri::HTML(html).at_css("main#main")
      return failure(:unavailable) unless main
      return failure(:identity_mismatch) unless AdvocaatBeProfileLookup.names_match?(main.at_css("h1")&.text&.squish, @full_name)

      profile = self.class.attributes_from(main)
      # Location keys are intentionally present as nil when the page is valid but
      # no longer publishes them, so a sync can clear stale saved values. A page
      # with no supported data at all is still treated as empty.
      return failure(:empty) if profile.empty? || profile.values.all?(&:blank?)

      Result.new(status: :ok, profile_attributes: profile)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError, ResponseTooLarge
      failure(:unavailable)
    end

    private

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
          next unless response.is_a?(Net::HTTPSuccess)
          next unless response["content-type"].to_s.downcase.include?("text/html")

          body = +"".b
          response.read_body do |chunk|
            if body.bytesize + chunk.bytesize > MAX_BODY_BYTES
              raise ResponseTooLarge
            end
            body << chunk
          end
        end
        body
      end
    end

    def failure(status)
      Result.new(status:, profile_attributes: {})
    end
  end
end
