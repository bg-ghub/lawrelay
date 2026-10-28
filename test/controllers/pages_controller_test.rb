require "test_helper"

class PagesControllerTest < ActionController::TestCase
  tests PagesController

  %i[pricing privacy terms cookie_policy legal_notice].each do |page|
    test "renders #{page} in every supported locale" do
      I18n.available_locales.each do |locale|
        get page, params: { locale: locale }

        assert_response :success
        assert_select "html[lang='#{locale}']"
        assert_not_includes response.body, "Translation missing"
      end
    end
  end

  test "does not invent missing operator information" do
    get :legal_notice, params: { locale: "en" }

    assert_response :success
    assert_select ".form-error"
    assert_includes response.body, I18n.t("pages.shared.not_configured", locale: :en)
  end

  test "renders the general contact address in the footer for every supported locale" do
    I18n.available_locales.each do |locale|
      get :pricing, params: { locale: locale }

      assert_response :success
      assert_select "a[href='mailto:info@lawrelay.be']", text: "info@lawrelay.be"
      assert_select ".footer-label", text: I18n.t("marketing.footer.contact", locale: locale)
    end
  end
end
