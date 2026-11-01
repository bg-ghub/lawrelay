module Matching
  class AssignmentSuggestions
    LIMIT = 3
    PRACTICE_AREA_ALIASES = {
      "employment" => [ "employment law", "arbeidsrecht", "droit du travail", "arbeitsrecht" ],
      "family" => [ "family and youth law", "familie en jeugdrecht", "familierecht", "droit de la famille et de la jeunesse", "familien und jugendrecht" ],
      "commercial" => [ "commercial law", "handelsrecht", "droit commercial", "handelsrecht" ],
      "corporate" => [ "corporate law", "ondernemingsrecht", "vennootschapsrecht", "droit des societes", "gesellschaftsrecht" ],
      "criminal" => [ "criminal law", "strafrecht", "droit penal", "strafrecht" ],
      "immigration" => [ "immigration law", "vreemdelingenrecht", "droit des etrangers", "auslanderrecht" ],
      "other" => [ "other", "ander", "autre", "andere" ]
    }.freeze

    def initialize(user:, limit: LIMIT)
      @user = user
      @profile = user.lawyer_profile
      @limit = limit
    end

    def call
      return [] unless @profile

      candidates.filter_map do |assignment|
        score = score_for(assignment)
        [ assignment, score ] if score.positive?
      end
        .sort_by { |assignment, score| [ -score, assignment.starts_at, assignment.id ] }
        .first(@limit)
        .map(&:first)
    end

    private

    def candidates
      Assignment.accepting_proposals
        .where.not(firm_id: @user.firm_ids)
        .includes(:firm)
    end

    def score_for(assignment)
      score = 0
      score += 4 if court_coverage_matches?(assignment)
      score += 3 if practice_area_matches?(assignment)
      score += 2 if assignment.legal_task? && language_matches?(assignment)
      score
    end

    def court_coverage_matches?(assignment)
      coverage = @profile.court_preferences.map { |value| normalize(value) }.reject(&:blank?)
      location = normalize([ assignment.court, assignment.city ].compact.join(" "))
      return false if coverage.empty? || location.blank?

      assigned = Array(courts_by_label[normalize(assignment.court)]).select { |court| court.fetch(:cities).include?(normalize(assignment.city)) }
      coverage.any? do |preference|
        preferred = Array(courts_by_label[preference])
        if preferred.any?
          (preferred & assigned).any?
        elsif (cities = city_aliases[preference])
          cities.include?(normalize(assignment.city))
        else
          location.include?(preference) || preference.include?(location)
        end
      end
    end

    def courts_by_label
      @courts_by_label ||= CourtCatalogue.options(locale: :nl).each_with_index.each_with_object({}) do |(court, index), labels|
        record = { id: index, cities: court.fetch(:cities).map { |city| normalize(city) } }
        court.fetch(:labels).each { |label| (labels[normalize(label)] ||= []) << record }
      end
    end

    def city_aliases
      @city_aliases ||= CourtCatalogue::DATA.fetch("places").each_with_object({}) do |(name, translations), aliases|
        variants = [ name, *translations.values ].map { |value| normalize(value) }.uniq
        variants.each { |variant| aliases[variant] = (Array(aliases[variant]) + variants).uniq }
      end
    end

    def practice_area_matches?(assignment)
      assignment_area = practice_area_key(assignment.practice_area)
      @profile.practice_areas.any? { |area| practice_area_key(area) == assignment_area }
    end

    def language_matches?(assignment)
      assignment_languages = normalized_languages(assignment.languages)
      profile_languages = normalized_languages(@profile.spoken_languages)
      (assignment_languages & profile_languages).any?
    end

    def normalized_languages(values)
      aliases = {
        "NL" => %w[NL NEDERLANDS DUTCH NÉERLANDAIS NEERLANDAIS NIEDERLÄNDISCH NIEDERLANDISCH],
        "FR" => %w[FR FRANÇAIS FRANCAIS FRENCH FRANZÖSISCH FRANZOSISCH],
        "DE" => %w[DE DEUTSCH GERMAN ALLEMAND DUITS],
        "EN" => %w[EN ENGLISH ANGLAIS ENGELS ENGLISCH]
      }
      tokens = Array(values).flat_map { |value| value.to_s.upcase.split(/[^\p{L}]+/) }.reject(&:blank?)
      aliases.filter_map { |key, names| key if (tokens & names).any? }
    end

    def normalize(value)
      I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def practice_area_key(value)
      normalized = normalize(value)
      practice_area_keys.fetch(normalized, normalized)
    end

    def practice_area_keys
      @practice_area_keys ||= begin
        keys = {}
        PRACTICE_AREA_ALIASES.each do |key, aliases|
          aliases.each { |label| keys[normalize(label)] = key }
        end
        I18n.available_locales.each do |locale|
          I18n.t("marketplace.practice_areas", locale: locale).each do |key, label|
            keys[normalize(label)] = key.to_s
          end
        end
        keys
      end
    end
  end
end
