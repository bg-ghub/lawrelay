module TravelHelper
  def travel_estimate_text(estimate)
    return t("travel.#{estimate.status}") unless estimate.ready?

    t("travel.summary", distance: number_with_precision(estimate.distance_meters / 1000.0,
      precision: 1, strip_insignificant_zeros: true), minutes: [ (estimate.duration_seconds / 60.0).ceil, 1 ].max)
  end
end
