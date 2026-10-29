module ApplicationHelper
  def platform_billing_enabled?
    ENV.fetch("LAWRELAY_RELEASE_MODE", "beta") == "paid"
  end

  def euro_amount(cents, field: false)
    return if cents.nil?

    options = { precision: 2, strip_insignificant_zeros: true }
    options.merge!(separator: ".", delimiter: "") if field
    number_with_precision(cents.to_d / 100, **options)
  end

  def public_marketing_page?
    request.get? && controller_path.in?(%w[home pages])
  end

  def localized_canonical_url(locale)
    url_for(request.path_parameters.merge(locale:, only_path: false))
  end
end
