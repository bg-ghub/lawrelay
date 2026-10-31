class CourtCatalogue
  DATA = JSON.parse(Rails.root.join("config/courts.be.json").read).freeze
  LOCALES = %i[nl fr de en].freeze

  def self.options(locale: I18n.locale)
    locale = locale.to_sym
    locale = :en unless locale.in?(LOCALES)

    DATA.fetch("courts").map do |court|
      labels = LOCALES.map { |language| label(court, language) }
      {
        label: label(court, locale),
        city: place(court.fetch("city"), locale),
        labels: labels.uniq,
        cities: LOCALES.map { |language| place(court.fetch("city"), language) }.uniq,
        search: (labels + [ court.fetch("city"), court.fetch("venue"), court.fetch("district"), aliases(court) ]).join(" ")
      }
    end.sort_by { |court| I18n.transliterate(court.fetch(:label)).downcase }
  end

  def self.label(court, locale)
    type = I18n.t("court_picker.types.#{court.fetch('type')}", locale:)
    name = court.fetch("type") == "peace" ? venue(court.fetch("venue"), locale) : place(court.fetch("district"), locale)
    name += " (#{I18n.t("court_picker.languages.#{court['language']}", locale:)})" if court["language"]
    text = "#{type} #{name}"
    if court.fetch("division")
      text += " — #{I18n.t('court_picker.division', locale:)} #{place(court.fetch('venue'), locale)}"
    elsif court.fetch("type") == "assize" && name != place(court.fetch("city"), locale)
      text += " — #{place(court.fetch('city'), locale)}"
    elsif !court.fetch("division") && court.fetch("district") != court.fetch("city") && court.fetch("type") != "peace"
      text += " — #{place(court.fetch('city'), locale)}"
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
