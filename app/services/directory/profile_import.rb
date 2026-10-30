require "net/http"
require "nokogiri"

module Directory
  class ProfileImport
    class ResponseTooLarge < StandardError; end
    Result = Data.define(:status, :profile_attributes) do
      def success? = status == :ok
    end

    MAX_BODY_BYTES = 1.megabyte
    LANGUAGE_CODES = { "nederlands" => "NL", "frans" => "FR", "duits" => "DE", "engels" => "EN" }.freeze
    PRACTICE_LABELS = %w[voorkeurmateries rechtsdomeinen vakgebieden].freeze

    def self.call(profile_url:, full_name:, fetcher: nil)
      new(profile_url:, full_name:, fetcher:).call
    end

    def initialize(profile_url:, full_name:, fetcher: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @full_name = full_name
      @fetcher = fetcher || method(:fetch_html)
    end

    def call
      return failure(:missing_profile) unless @profile_url

      html = @fetcher.call(URI(@profile_url))
      return failure(:unavailable) if html.blank? || html.bytesize > MAX_BODY_BYTES

      main = Nokogiri::HTML(html).at_css("main#main")
      return failure(:unavailable) unless main
      return failure(:identity_mismatch) unless AdvocaatBeProfileLookup.names_match?(main.at_css("h1")&.text&.squish, @full_name)

      profile = {}
      languages = labelled_values(main, %w[talen]).map { |value| LANGUAGE_CODES.fetch(value.downcase, value) }
      profile[:spoken_languages] = languages if languages.any?
      areas = labelled_values(main, PRACTICE_LABELS)
      profile[:practice_areas] = areas if areas.any?
      return failure(:empty) if profile.empty?

      Result.new(status: :ok, profile_attributes: profile)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError, ResponseTooLarge
      failure(:unavailable)
    end

    private

    def labelled_values(main, labels)
      heading = main.css("h2, h3").find { |element| labels.include?(element.text.squish.downcase) }
      content = heading&.next_element
      return [] unless content && content.name.in?(%w[p ul ol])

      values = content.name == "p" ? content.text.split(/[,;\n]/) : content.css("li").map(&:text)
      values.map { |value| value.squish.first(100) }.reject(&:blank?).uniq.first(20)
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
