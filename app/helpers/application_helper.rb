module ApplicationHelper
  def public_marketing_page?
    request.get? && controller_path.in?(%w[home pages])
  end

  def localized_canonical_url(locale)
    url_for(request.path_parameters.merge(locale:, only_path: false))
  end
end
