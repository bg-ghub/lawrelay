module ApplicationHelper
  SOCIAL_LOCALES = { nl: "nl_BE", fr: "fr_BE", de: "de_BE", en: "en_GB" }.freeze

  def professional_salutation(user)
    return user.full_name if user.system_admin? || I18n.locale == :en

    t("lawyer_titles.salutation", name: user.last_name.presence || user.full_name)
  end

  def advocaat_webmail_address?(email)
    email.to_s.strip.match?(/\A[^@\s]+@advocaat\.be\z/i)
  end

  def advocaat_webmail_hint(email, registration: false)
    matches = advocaat_webmail_address?(email)
    return unless registration || matches

    options = { class: "field-hint advocaat-webmail-hint" }
    if registration
      options[:class] += " registration-profile__listed-email-notice"
      options[:hidden] = !matches
      options[:data] = { registration_profile_target: "webmailHint" }
    end
    destination = link_to "webmail.advocaat.be", "https://webmail.advocaat.be/",
      target: "_blank", rel: "noopener noreferrer", class: "text-link"
    tag.p t("directory_onboarding.webmail_hint_html", link: destination), **options
  end

  def searchable_select(form, method, choices, options = {}, html_options = {})
    tag.div(class: "searchable-select", data: {
      controller: "searchable-select",
      searchable_select_placeholder_value: t("searchable_select.placeholder"),
      searchable_select_empty_value: t("searchable_select.empty"),
      searchable_select_choose_value: t("searchable_select.choose"),
      searchable_select_count_value: t("searchable_select.results", number: "%{count}")
    }) do
      form.select(method, choices, options, html_options.deep_merge(data: { searchable_select_target: "source" }))
    end
  end

  def assignment_practice_area_choice(assignment)
    return Assignment::OTHER_CHOICE unless assignment.practice_area_other.nil?
    return if assignment.practice_area.blank?

    key = I18n.available_locales.filter_map do |locale|
      I18n.t("marketplace.practice_areas", locale:).key(assignment.practice_area)
    end.first
    return Assignment::OTHER_CHOICE if key.nil? || key.to_s == "other"

    t("marketplace.practice_areas.#{key}")
  end

  def assignment_practice_area_other_value(assignment)
    return assignment.practice_area_other unless assignment.practice_area_other.nil?
    return unless assignment_practice_area_choice(assignment) == Assignment::OTHER_CHOICE
    return if I18n.available_locales.any? { |locale| I18n.t("marketplace.practice_areas.other", locale:) == assignment.practice_area }

    assignment.practice_area
  end

  def platform_billing_enabled?
    ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
  end

  def euro_amount(cents, field: false)
    return if cents.nil?

    options = { precision: cents.to_d.modulo(100).zero? ? 0 : 2, strip_insignificant_zeros: field }
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
