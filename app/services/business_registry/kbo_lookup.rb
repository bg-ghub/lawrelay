require "uri"

module BusinessRegistry
  class KboLookup
    BASE_URL = "https://kbopub.economie.fgov.be/kbopub/toonondernemingps.html".freeze
    LOCALES = %w[nl fr de en].freeze

    # Public Search permits a targeted consultation, but not reuse of its
    # results. Open the official record rather than scraping it into LawRelay.
    def self.url_for(enterprise_number:, locale: I18n.locale)
      number = Firm.normalize_enterprise_number(enterprise_number)
      return unless Firm.valid_enterprise_number?(number)

      language = locale.to_s.in?(LOCALES) ? locale.to_s : "nl"
      "#{BASE_URL}?#{URI.encode_www_form(ondernemingsnummer: number, lang: language)}"
    end
  end
end
