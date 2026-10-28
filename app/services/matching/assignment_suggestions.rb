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
      Assignment.open.upcoming
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

      coverage.any? { |preference| location.include?(preference) || preference.include?(location) }
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
      PRACTICE_AREA_ALIASES.each do |key, aliases|
        return key if aliases.any? { |candidate| normalize(candidate) == normalized }
      end
      normalized
    end
  end
end
