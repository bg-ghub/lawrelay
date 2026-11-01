class CourtCatalogue
  DATA = JSON.parse(Rails.root.join("config/courts.be.json").read).freeze
  LOCALES = %i[nl fr de en].freeze

  def self.options(locale: I18n.locale)
    DATA.fetch("courts").map { |court| option_for(court, locale:) }
      .sort_by { |court| I18n.transliterate(court.fetch(:label)).downcase }
  end

  def self.court_name(court, locale: I18n.locale)
    locale = locale.to_sym
    label(court, LOCALES.include?(locale) ? locale : :en, hearing: false)
  end

  def self.option_for(court, locale: I18n.locale)
    locale = locale.to_sym
    locale = :en unless locale.in?(LOCALES)

    current_labels = LOCALES.map { |language| label(court, language) }.uniq
    labels = (current_labels + LOCALES.flat_map do |language|
      [ label(court, language, hearing: false), label(court, language, hearing: false, official: false) ]
    end).uniq
    city_names = [ court.fetch("city"), court["judicial_city"] ].compact.uniq
    cities = city_names.flat_map { |name| LOCALES.map { |language| place(name, language) } }.uniq
    {
      label: label(court, locale),
      city: place(court.fetch("city"), locale),
      labels:,
      current_labels:,
      cities:,
      hearing_verified: court.fetch("hearing_verified", true),
      search: (labels + cities + city_names + [ court.fetch("venue"), court.fetch("district"), aliases(court) ]).join(" ")
    }
  end

  def self.label(court, locale, hearing: true, official: true)
    type = I18n.t("court_picker.types.#{court.fetch('type')}", locale:)
    return type if official && %w[cassation constitutional state].include?(court.fetch("type"))
    if official && court.fetch("type") == "assize" && court.fetch("district") == "Brussel"
      return I18n.t("court_picker.brussels_assize", locale:)
    end

    name = court.fetch("type") == "peace" ? venue(court.fetch("venue"), locale) : place(court.fetch("district"), locale)
    name += " (#{I18n.t("court_picker.languages.#{court['language']}", locale:)})" if court["language"]
    text = "#{type} #{name}"
    judicial_city = court.fetch("judicial_city", court.fetch("city"))
    if court.fetch("division")
      text += " — #{I18n.t('court_picker.division', locale:)} #{place(court.fetch('venue'), locale)}"
    elsif court.fetch("type") == "assize" && name != place(judicial_city, locale)
      text += " — #{place(judicial_city, locale)}"
    elsif court.fetch("district") != judicial_city && court.fetch("type") != "peace"
      text += " — #{place(judicial_city, locale)}"
    end
    if hearing && court["hearing_verified"] == false
      text += " — #{I18n.t('court_picker.hearing_unconfirmed', locale:)}"
    elsif hearing && court["hearing_place"]
      text += " — #{I18n.t('court_picker.hearing_place', locale:, place: place(court.fetch('hearing_place'), locale))}"
      text += " — #{court.fetch('hearing_address')}" if court["hearing_address"]
      text += " (#{I18n.t("court_picker.hearing_subjects.#{court.fetch('hearing_subject')}", locale:)})" if court["hearing_subject"]
    end
    text
  end

  def self.place(name, locale)
    DATA.fetch("places").dig(name, locale.to_s) || name
  end

  def self.venue(name, locale)
    translated = name.dup
    DATA.fetch("places").keys.sort_by { |key| -key.length }.each do |key|
      translated = translated.gsub(/\b#{Regexp.escape(key)}\b/, place(key, locale))
    end
    return translated if locale == :nl

    translated = translated.gsub("1e kanton", { fr: "1er canton", de: "1. Kanton", en: "1st canton" }.fetch(locale))
    translated = translated.gsub(/(\d)e kanton/) do
      number = Regexp.last_match(1)
      { fr: "#{number}e canton", de: "#{number}. Kanton", en: "canton #{number}" }.fetch(locale)
    end
    translated = translated.gsub("eerste kanton", I18n.t("court_picker.first_canton", locale:))
      .gsub("tweede kanton", I18n.t("court_picker.second_canton", locale:))
    translated
  end

  def self.aliases(court)
    return "" unless court.fetch("type") == "first_instance"

    "familierechtbank jeugdrechtbank correctionele rechtbank burgerlijke rechtbank tribunal famille jeunesse correctionnel civil Familiengericht Jugendgericht Strafgericht family juvenile criminal civil court"
  end

  private_class_method :label, :place, :venue, :aliases
end
