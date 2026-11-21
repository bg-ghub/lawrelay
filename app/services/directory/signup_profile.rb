require "net/http"
require "nokogiri"

module Directory
  class SignupProfile
    Result = Data.define(:status, :profile_url, :name, :first_name, :last_name, :email_address, :profile_attributes, :original_profile_url) do
      def initialize(profile_url:, original_profile_url: profile_url, **attributes)
        super(profile_url:, original_profile_url:, **attributes)
      end

      def success? = status == :ok
    end

    MAX_BODY_BYTES = ProfilePage::MAX_BODY_BYTES

    def self.call(profile_url:, fetcher: nil)
      new(profile_url:, fetcher:).call
    end

    def initialize(profile_url:, fetcher: nil)
      @profile_url = AdvocaatBeProfileLookup.canonical_profile_url(profile_url)
      @fetcher = fetcher
    end

    def call
      return failure(:invalid_url) unless @profile_url

      page = Timeout.timeout(ProfilePage::TIMEOUT_SECONDS) { ProfilePage.resolve(@profile_url, fetcher: @fetcher) }
      return failure(:unavailable) unless page&.html?

      main = ProfilePage.main(page.body)
      name = main&.at_css("h1")&.text&.squish
      return failure(:malformed) if name.blank? || name.length > 201

      email = ProfilePage.listed_email(main)
      return failure(:email_missing) unless email

      first_name, last_name = name.split(/\s+/, 2)
      # This is an editable suggestion, not verified given/family-name evidence.
      # Keep unusual names manual rather than truncating the directory identity.
      first_name = "" if first_name.to_s.length > 100
      last_name = "" if last_name.to_s.length > 100
      Result.new(status: :ok, profile_url: page.uri.to_s, original_profile_url: @profile_url, name:, first_name: first_name.to_s,
        last_name: last_name.to_s, email_address: email, profile_attributes: ProfileImport.attributes_from(main))
    rescue Timeout::Error, SocketError, IOError, SystemCallError,
      OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError, Nokogiri::XML::SyntaxError
      failure(:unavailable)
    end

    private

    def failure(status)
      Result.new(status:, profile_url: @profile_url, name: nil, first_name: nil, last_name: nil,
        email_address: nil, profile_attributes: {})
    end
  end
end
