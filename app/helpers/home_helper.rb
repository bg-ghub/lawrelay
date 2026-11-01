module HomeHelper
  HeroAssignment = Struct.new(
    :kind, :urgent, :title, :description, :starts_at, :court, :city, :practice_area, :fee_cents,
    keyword_init: true
  ) do
    def urgent?
      urgent
    end

    def court_replacement?
      kind == "court_replacement"
    end
  end

  def home_preview_assignment
    court = CourtCatalogue::DATA.fetch("courts").find do |entry|
      entry["type"] == "first_instance" && entry["district"] == "Antwerpen" && entry["venue"] == "Antwerpen"
    end
    choice = CourtCatalogue.option_for(court, locale: I18n.locale)
    HeroAssignment.new(
      kind: "court_replacement",
      urgent: false,
      title: t("marketing.home.product.title"),
      description: t("marketing.home.product.description"),
      starts_at: Time.zone.tomorrow.in_time_zone.change(hour: 10),
      court: choice.fetch(:label),
      city: choice.fetch(:city),
      practice_area: t("marketing.home.product.practice_area"),
      fee_cents: nil
    )
  end
end
