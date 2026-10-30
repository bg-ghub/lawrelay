class ErrorsController < ActionController::Base
  AVAILABLE_LOCALES = %w[nl fr de en].freeze
  def show
    I18n.with_locale(locale) do
      @status = params[:status].to_i
      @message = @status == 404 ? "404" : (@status >= 500 ? "500" : "422")
      response.headers["X-Robots-Tag"] = "noindex, nofollow"
      render :show, formats: [ :html ], content_type: "text/html", status: @status, layout: false
    end
  end

  private

  def locale
    original_path = request.get_header("action_dispatch.original_path").to_s
    original_path = request.get_header("ORIGINAL_FULLPATH").to_s if original_path.blank?
    original_path[%r{\A/(nl|fr|de|en)(?:/|\z)}, 1].presence_in(AVAILABLE_LOCALES) || I18n.default_locale
  end
end
