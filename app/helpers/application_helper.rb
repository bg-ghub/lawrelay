module ApplicationHelper
  SOCIAL_LOCALES = { nl: "nl_BE", fr: "fr_BE", de: "de_BE", en: "en_GB" }.freeze

  def platform_billing_enabled?
    ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
  end

  def euro_amount(cents, field: false)
    return if cents.nil?

    options = { precision: 2, strip_insignificant_zeros: true }
    options.merge!(separator: ".", delimiter: "") if field
    number_with_precision(cents.to_d / 100, **options)
  end

  def public_marketing_page?
    request.get? && controller_path.in?(%w[home pages])
  end

  def localized_canonical_url(locale)
    url_for(request.path_parameters.merge(locale:, only_path: false))
  end

  def page_title
    content_for(:title).presence || t("marketing.layout.title")
  end

  def page_description
    content_for(:meta_description).presence || t("marketing.layout.description")
  end

  def social_preview_image_url
    SiteHosts.main_url("/images/social/lawrelay-#{I18n.locale}.png")
  end

  def social_preview_locale(locale = I18n.locale)
    SOCIAL_LOCALES.fetch(locale.to_sym)
  end

  def app_version_label
    key = Firm.beta_mode? ? "marketing.footer.beta_version" : "marketing.footer.app_version"
    t(key, version: LawRelay::VERSION)
  end
end
