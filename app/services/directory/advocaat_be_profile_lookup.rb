require "net/http"
require "nokogiri"
require_relative "profile_page"

module Directory
  class AdvocaatBeProfileLookup
    Result = Data.define(:status, :profile_id, :source_url, :name, :email, :checked_at, :original_profile_id) do
      def initialize(profile_id:, original_profile_id: profile_id, **attributes)
        super(profile_id:, original_profile_id:, **attributes)
      end

      def success? = status == :ok
    end

    UUID = "[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}"
    HOSTS = %w[advocaat.be www.advocaat.be].freeze
    PROFILE_URL = %r{\Ahttps://(?:#{Regexp.union(HOSTS).source})(?::443)?(/nl/zoek-een-advocaat/advocaat/#{UUID})\z}i
    MAX_BODY_BYTES = ProfilePage::MAX_BODY_BYTES

    def self.call(profile_url:, full_name:, fetcher: nil)
      new(profile_url:, full_name:, fetcher:).call
    end

    def self.canonical_profile_url(profile_url)
      url = profile_url.to_s
      return unless url.ascii_only?
      match = PROFILE_URL.match(url)
      return unless match

      "https://www.advocaat.be#{match[1].downcase}"
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
      @profile_url = self.class.canonical_profile_url(profile_url)
      @full_name = full_name.to_s
      @fetcher = fetcher
    end

    def call
      return failure(:invalid_url) unless @profile_url

      page = Timeout.timeout(ProfilePage::TIMEOUT_SECONDS) { ProfilePage.resolve(@profile_url, fetcher: @fetcher) }
      return failure(:invalid_url) if page&.missing? && page.uri.to_s == @profile_url
      return failure(:unavailable) unless page&.html?

      main = ProfilePage.main(page.body)
      return failure(:malformed) unless main

      name = main.at_css("h1")&.text&.squish
      return failure(:name_mismatch) unless self.class.names_match?(name, @full_name)

      email = ProfilePage.listed_email(main)
      return failure(:email_missing) unless email

      Result.new(status: :ok, profile_id: page.uri.path.split("/").last, original_profile_id: @profile_url.split("/").last,
        source_url: page.uri.to_s, name:, email:, checked_at: Time.current)
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
      failure(:unavailable)
    rescue Nokogiri::XML::SyntaxError
      failure(:malformed)
    end

    private

    def failure(status)
      Result.new(status:, profile_id: nil, source_url: nil, name: nil, email: nil, checked_at: nil)
    end
  end
end
