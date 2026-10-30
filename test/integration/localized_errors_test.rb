require "test_helper"
require "action_dispatch/middleware/show_exceptions"
require "nokogiri"

class LocalizedErrorsTest < ActionDispatch::IntegrationTest
  test "error responses use the original URL locale and stay short" do
    {
      nl: "Pagina niet gevonden",
      fr: "Page introuvable",
      de: "Seite nicht gefunden",
      en: "Page not found"
    }.each do |locale, heading|
      response = render_error(404, "/#{locale}/missing")

      assert_equal 404, response.fetch(:status)
      assert_localized_page(response.fetch(:body), locale:, heading:)
      refute_match(/exception|stack trace|NoMethodError/i, response.fetch(:body))
    end
  end

  test "unprocessable and server errors are localized without a locale fallback leak" do
    response = render_error(422, "/fr/settings")
    assert_equal 422, response.fetch(:status)
    assert_localized_page(response.fetch(:body), locale: :fr, heading: "Réessayez")

    response = render_error(500, "/unknown")
    assert_equal 500, response.fetch(:status)
    assert_localized_page(response.fetch(:body), locale: :nl, heading: "Er ging iets mis")
    assert_equal "noindex, nofollow", response.fetch(:headers)["x-robots-tag"]
  end

  test "the exception middleware uses the renderer for a missing localized route" do
    app = ->(_env) { raise ActionController::RoutingError, "missing route" }
    env = Rack::MockRequest.env_for("/fr/route-that-does-not-exist")
    env["action_dispatch.show_exceptions"] = :all
    env["action_dispatch.backtrace_cleaner"] = Rails.backtrace_cleaner

    status, headers, body = ActionDispatch::ShowExceptions.new(app, Rails.application.routes).call(env)
    rendered = body.each.to_a.join

    assert_equal 404, status
    assert_equal "noindex, nofollow", headers["x-robots-tag"]
    assert_localized_page(rendered, locale: :fr, heading: "Page introuvable")
  end

  test "other client errors keep their original status" do
    response = render_error(406, "/de/anything")

    assert_equal 406, response.fetch(:status)
    assert_localized_page(response.fetch(:body), locale: :de, heading: "Bitte erneut versuchen")
  end

  test "non HTML accepts still receive the safe localized HTML error page" do
    [ "application/json", "image/png" ].each do |accept|
      response = render_error(404, "/fr/missing", accept:)

      assert_equal 404, response.fetch(:status)
      assert_match(%r{\Atext/html}, response.fetch(:headers)["content-type"])
      assert_localized_page(response.fetch(:body), locale: :fr, heading: "Page introuvable")
    end
  end

  private

  def render_error(status, original_path, accept: "text/html")
    env = Rack::MockRequest.env_for("/#{status}", "HTTP_ACCEPT" => accept)
    env["action_dispatch.original_path"] = original_path
    response_status, headers, body = Rails.application.routes.call(env)
    { status: response_status, headers:, body: body.each.to_a.join }
  end

  def assert_localized_page(body, locale:, heading:)
    document = Nokogiri::HTML5(body)
    assert_equal locale.to_s, document.at_css("html")["lang"]
    assert_equal heading, document.at_css("h1").text
    assert_equal "noindex,nofollow", document.at_css("meta[name='robots']")["content"]
    assert_equal "/#{locale}", document.at_css("a")["href"]
  end
end
