class PracticeAreaCatalogue
  def self.key(value)
    return if value.blank?

    I18n.available_locales.filter_map do |locale|
      I18n.t("marketplace.practice_areas", locale:).key(value)
    end.first
  end

  def self.label(value, locale: I18n.locale)
    area_key = key(value)
    area_key ? I18n.t("marketplace.practice_areas.#{area_key}", locale:) : value
  end

  def self.equivalents(value)
    area_key = key(value)
    return Array(value) unless area_key

    I18n.available_locales.map { |locale| I18n.t("marketplace.practice_areas.#{area_key}", locale:) }.uniq
  end

  def self.filter_options(values, selected: nil, locale: I18n.locale)
    selected_key = key(selected)
    seen = {}
    values.filter_map do |value|
      area_key = key(value)
      identity = area_key ? [ :standard, area_key ] : [ :custom, value ]
      next if seen[identity]

      seen[identity] = true
      option_value = area_key && area_key == selected_key ? selected : value
      [ label(value, locale:), option_value ]
    end
  end
end
