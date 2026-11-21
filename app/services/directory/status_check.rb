require "net/http"
require "nokogiri"
require "timeout"
require "uri"

module Directory
  # Reports public directory evidence without changing accounts or retaining
  # another copy of a lawyer's contact details.
  class StatusCheck
    Result = Data.define(:status, :checked_at, :resolved_profile_id) do
      def initialize(status:, checked_at:, resolved_profile_id: nil)
        super
      end
    end

    MAX_BODY_BYTES = ProfilePage::MAX_BODY_BYTES
    TIMEOUT_SECONDS = ProfilePage::TIMEOUT_SECONDS

    def self.call(profile_url:, full_name:, expected_email: nil, transport: nil)
      new(profile_url:, full_name:, expected_email:, transport:).call
    end

    def initialize(profile_url:, full_name:, expected_email: nil, transport: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @full_name = full_name.to_s
      @expected_email = expected_email&.to_s&.strip&.downcase
      @fetcher = ->(uri) { transport.call(uri, ProfilePage.request_for(uri)) } if transport
    end

    def call
      return result(:unavailable) unless @profile_url && @full_name.present?
      return result(:unavailable) if @expected_email && !@expected_email.match?(URI::MailTo::EMAIL_REGEXP)

      Timeout.timeout(TIMEOUT_SECONDS) do
        page = ProfilePage.resolve(@profile_url, allow_redirect: @expected_email.present?, fetcher: @fetcher)
        return result(:not_listed) if page&.missing? && page.uri.to_s == @profile_url
        return result(:unavailable) unless page&.html?

        main = ProfilePage.main(page.body)
        return result(:unavailable) unless main
        name = main.at_css("h1").text.squish
        email = ProfilePage.listed_email(main)
        return result(:unavailable) unless name.present? && email
        return result(:changed) unless AdvocaatBeProfileLookup.names_match?(name, @full_name)
        return result(:changed) if @expected_email && email != @expected_email

        result(:active, resolved_profile_id: @expected_email ? page.uri.path.split("/").last : nil)
      end
    rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError, ArgumentError, Encoding::CompatibilityError
      result(:unavailable)
    end

    private

    def result(status, resolved_profile_id: nil)
      Result.new(status:, checked_at: Time.current, resolved_profile_id:)
    end
  end
end
