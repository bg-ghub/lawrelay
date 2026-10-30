module HomeHelper
  HeroAssignment = Struct.new(
    :kind, :urgent, :title, :description, :starts_at, :court, :city, :practice_area, :fee_cents,
    keyword_init: true
  ) do
    def urgent?
      urgent
    end
  end

  def home_preview_assignment
    HeroAssignment.new(
      kind: "court_replacement",
      urgent: false,
      title: t("marketing.home.product.title"),
      description: t("marketing.home.product.description"),
      starts_at: Time.zone.tomorrow.in_time_zone.change(hour: 10),
      court: t("marketing.home.product.court"),
      city: t("marketing.home.product.city"),
      practice_area: t("marketing.home.product.practice_area"),
      fee_cents: nil
    )
  end
end
