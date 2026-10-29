require "test_helper"

class PagesControllerTest < ActionController::TestCase
  tests PagesController

  %i[privacy terms cookie_policy legal_notice].each do |page|
    test "renders #{page} in every supported locale" do
      I18n.available_locales.each do |locale|
        get page, params: { locale: locale }

        assert_response :success
        assert_select "html[lang='#{locale}']"
        assert_not_includes response.body, "Translation missing"
      end
    end
  end

  test "beta pricing URLs redirect to the localized home page" do
    with_release_mode("beta") do
      I18n.available_locales.each do |locale|
        get :pricing, params: { locale: locale }

        assert_redirected_to root_path(locale: locale)
      end
    end
  end

  test "the archived pricing page remains available only in paid mode" do
    with_release_mode("paid") do
      I18n.available_locales.each do |locale|
        get :pricing, params: { locale: locale }

        assert_response :success
        assert_select "html[lang='#{locale}']"
        assert_select "h1", text: I18n.t("pages.pricing.title", locale: locale)
      end
    end
  end

  test "renders the configured operator and dedicated contact addresses" do
    get :legal_notice, params: { locale: "en" }

    assert_response :success
    assert_select ".form-error", count: 0
    assert_includes response.body, "Gauthier Berth"
    assert_includes response.body, "privacy@lawrelay.be"
    assert_includes response.body, "support@lawrelay.be"
  end

  test "renders the general contact address in the footer for every supported locale" do
    I18n.available_locales.each do |locale|
      get :privacy, params: { locale: locale }

      assert_response :success
      assert_select "a[href='mailto:info@lawrelay.be']", text: "info@lawrelay.be"
      assert_select ".footer-label", text: I18n.t("marketing.footer.contact", locale: locale)
    end
  end

  test "renders GitHub source, open-source status, and application version in every footer locale" do
    source_url = "https://github.com/bg-ghub/lawrelay"

    I18n.available_locales.each do |locale|
      get :privacy, params: { locale: locale }

      assert_response :success
      assert_select ".footer-project a.footer-project__source[href='#{source_url}']",
        text: /#{Regexp.escape(I18n.t("marketing.footer.source_code", locale: locale))}/
      assert_select ".footer-project .footer-project__license",
        text: "#{I18n.t('marketing.footer.open_source', locale: locale)} · AGPL-3.0+"
      assert_select ".footer-project .footer-project__version",
        text: I18n.t("marketing.footer.app_version", locale: locale, version: LawRelay::VERSION)
    end
  end

  private

  def with_release_mode(mode)
    original = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = mode
    yield
  ensure
    original.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = original
  end
end
