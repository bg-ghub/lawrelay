require "net/http"
require "nokogiri"
require "timeout"

module Directory
  class ProfileImport
    class ResponseTooLarge < StandardError; end
    Result = Data.define(:status, :profile_attributes, :redirected_profile_id) do
      def initialize(status:, profile_attributes:, redirected_profile_id: nil)
        super
      end

      def success? = status == :ok
    end

    MAX_BODY_BYTES = 1.megabyte
    TIMEOUT_SECONDS = 15
    LANGUAGE_CODES = { "nederlands" => "NL", "frans" => "FR", "duits" => "DE", "engels" => "EN" }.freeze
    PRACTICE_LABELS = %w[voorkeurmateries rechtsdomeinen vakgebieden].freeze
    BAR_LABELS = %w[balies balie barreaux barreau anwaltskammer anwaltskammern bars].freeze
    LOCATION_FIELDS = %i[directory_professional_address directory_bar_name].freeze

    def self.call(profile_url:, full_name:, expected_email: nil, fetcher: nil)
      new(profile_url:, full_name:, expected_email:, fetcher:).call
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

    def initialize(profile_url:, full_name:, expected_email: nil, fetcher: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @full_name = full_name
      @expected_email = expected_email&.strip
      @fetcher = fetcher || method(:fetch_html)
    end

    def call
      return failure(:missing_profile) unless @profile_url

      html, redirected_profile_id = Timeout.timeout(TIMEOUT_SECONDS) { fetch_profile }
      return failure(:unavailable) unless html.is_a?(String) && html.present? && html.bytesize <= MAX_BODY_BYTES

      mains = Nokogiri::HTML(html).css("main#main")
      return failure(:identity_mismatch) if @expected_email && mains.many?
      main = mains.first
      return failure(:unavailable) unless main
      return failure(:identity_mismatch) unless AdvocaatBeProfileLookup.names_match?(main.at_css("h1")&.text&.squish, @full_name)
      if @expected_email && (!main.css("h1").one? || !listed_email(main)&.casecmp?(@expected_email))
        return failure(:identity_mismatch)
      end

      profile = self.class.attributes_from(main)
      # Location keys are intentionally present as nil when the page is valid but
      # no longer publishes them, so a sync can clear stale saved values. A page
      # with no supported data at all is still treated as empty.
      return failure(:empty) if profile.empty? || profile.values.all?(&:blank?)

      Result.new(status: :ok, profile_attributes: profile, redirected_profile_id:)
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError, ResponseTooLarge
      failure(:unavailable)
    end

    private

    def fetch_profile
      response = @fetcher.call(URI(@profile_url))
      return [ response, nil ] unless response.is_a?(Net::HTTPRedirection)
      return unless %w[301 308].include?(response.code) && @expected_email.present?

      location = response["location"].to_s
      location = "https://www.advocaat.be#{location}" if location.start_with?("/")
      return unless location.match?(%r{\Ahttps://}i)
      target = URI.parse(location)
      return unless target.userinfo.nil? && target.query.nil? && target.fragment.nil?
      canonical = AdvocaatBeProfileLookup.canonical_profile_url(location)
      return unless canonical && canonical != @profile_url

      uri = URI(canonical)
      [ @fetcher.call(uri), AdvocaatBeProfileLookup::PATH.match(uri.path)[1].downcase ]
    rescue URI::Error
      nil
    end

    def listed_email(main)
      main.css("a[href]").each do |link|
        email = link["href"][/\Amailto:([^?]+)/i, 1]&.strip
        return email if email&.match?(URI::MailTo::EMAIL_REGEXP)
      end
      nil
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
          return response if response.is_a?(Net::HTTPRedirection)
          return unless response.is_a?(Net::HTTPSuccess)
          return unless response.content_type.to_s.casecmp?("text/html")

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
