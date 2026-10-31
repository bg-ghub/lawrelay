module BusinessRegistry
  # Public Search lists the registered name and legal form separately. Only a
  # recognized form from that record may be added to the company's display name.
  # NP is a display designation, used only for an explicit natural-person type.
  class RegisteredName
    # Dutch labels and abbreviations published by FOD Economie. Legacy forms
    # stay distinct: a BVBA must never be inferred to be a BV.
    LEGAL_FORMS = {
      "besloten vennootschap" => "BV",
      "naamloze vennootschap" => "NV",
      "coöperatieve vennootschap" => "CV",
      "vennootschap onder firma" => "VOF",
      "commanditaire vennootschap" => "CommV",
      "vereniging zonder winstoogmerk" => "VZW",
      "internationale vereniging zonder winstoogmerk" => "IVZW",
      "europese vennootschap" => "SE",
      "europese coöperatieve vennootschap" => "SCE",
      "europees economisch samenwerkingsverband" => "EESV",
      "stichting van openbaar nut" => "SON",
      "private stichting" => "PS",
      "besloten vennootschap met beperkte aansprakelijkheid" => "BVBA",
      "besloten vennootschap met beperkte aansprakelijkheid (met inbegrip van eenpersoonsvennootschap)" => "BVBA",
      "besloten vennootschap met beperkte aansprakelijkheid starter" => "S-BVBA",
      "coöperatieve vennootschap met beperkte aansprakelijkheid" => "CVBA",
      "coöperatieve vennootschap met onbeperkte aansprakelijkheid" => "CVOA",
      "gewone commanditaire vennootschap" => "Comm.V",
      "commanditaire vennootschap op aandelen" => "Comm. VA",
      "economisch samenwerkingsverband" => "ESV",
      "landbouwvennootschap" => "LV"
    }.freeze

    # The same registered form can occur in the name in French or German even
    # on the Dutch KBO page. These equivalents come from the official Belgian
    # SocialSecurity multilingual legal-form list, and are never used to infer
    # a form when the separate KBO legal-form field is missing or unknown.
    EQUIVALENT_ABBREVIATIONS = {
      "BV" => %w[SRL GMBH], "NV" => %w[SA AG], "CV" => %w[SC GEN.],
      "VOF" => %w[SNC OHG], "CommV" => %w[SCOMM KOMMG],
      "VZW" => %w[ASBL VOG], "IVZW" => %w[AISBL IVOG],
      "EESV" => %w[GEIE EWIV], "SON" => %w[FUP GNS], "PS" => %w[FP PRST],
      "BVBA" => %w[SPRL PGMBH], "S-BVBA" => %w[SPRL-S],
      "CVBA" => %w[SCRL GEN.MBH], "CVOA" => %w[SCRI GEN.MUBH],
      "Comm.V" => %w[SCS EKG], "Comm. VA" => %w[SCA KGAA],
      "ESV" => %w[GIE WIV], "LV" => [ "S. AGR.", "LG" ]
    }.freeze

    def self.call(name:, legal_form:, entity_type: nil)
      new(name:, legal_form:, entity_type:).call
    end

    def initialize(name:, legal_form:, entity_type: nil)
      @name = normalized(name)
      @legal_form = normalized(legal_form).downcase
      @entity_type = normalized(entity_type).downcase
    end

    def call
      return @name if @name.empty?

      abbreviation = if [ "natuurlijk persoon", "natuurlijke persoon" ].include?(@entity_type)
        "NP"
      else
        LEGAL_FORMS[@legal_form]
      end
      return @name unless abbreviation

      # Normalize an existing prefix/suffix, including B.V., (BV), or the full
      # registered form, rather than showing the legal form twice.
      short_forms = [ abbreviation, *EQUIVALENT_ABBREVIATIONS[abbreviation] ].map do |short|
        short.delete(". ").chars.map { |letter| Regexp.escape(letter) }.join("[.\\s]*") + "\\.?"
      end
      long_forms = LEGAL_FORMS.filter_map { |form, short| Regexp.escape(form) if short == abbreviation }
      form = "(?:#{(short_forms + long_forms).join('|')})"
      wrapped_form = "(?:\\(\\s*#{form}\\s*\\)|\\[\\s*#{form}\\s*\\]|#{form})"
      # A hyphen must be separated from the form: SPRL-S and S-BVBA are
      # distinct legacy forms, not SPRL/BVBA followed by a separator.
      prefix = /\A#{wrapped_form}(?=[\s,;:]|\z)[\s,;:\-]*/i
      suffix = /(?:[\s,;:]+-?[\s,;:]*#{wrapped_form}|\(\s*#{form}\s*\)|\[\s*#{form}\s*\])\z/i
      base = @name
      loop do
        stripped = base.sub(prefix, "").sub(suffix, "").strip
        return abbreviation if stripped.empty?
        break if stripped == base

        base = stripped
      end

      "#{abbreviation} #{base}"
    end

    private

    def normalized(value)
      value.to_s.gsub(/[[:space:]]+/, " ").strip
    end
  end
end
