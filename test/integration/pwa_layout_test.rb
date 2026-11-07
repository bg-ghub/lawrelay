require "test_helper"

class PwaLayoutTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "member site advertises one localized installation flow in every language" do
    host! SiteHosts.app_host
    https!

    %w[nl fr de en].each do |locale|
      get new_session_path(locale: locale)
      assert_response :success
      assert_select "link[rel='manifest'][href='/#{locale}/manifest.webmanifest']", count: 1
      assert_select "meta[name='apple-mobile-web-app-capable'][content='yes']", count: 1
      assert_select "[data-pwa-install-banner][data-service-worker-url='/service-worker.js'][hidden]", count: 1
      assert_select "button[data-pwa-open-install]", count: 1
      assert_select "button[data-pwa-install]", text: I18n.t("pwa.install.button", locale: locale)
      assert_select "link[data-lawrelay-stylesheet='pwa_install']", count: 1
      assert_no_match(/translation missing/i, response.body)
    end
  end

  test "admin login does not advertise or render app installation" do
    host! SiteHosts.admin_host
    https!

    get admin_login_path(locale: :en)
    assert_response :success
    assert_select "link[rel='manifest']", count: 0
    assert_select "meta[name='apple-mobile-web-app-capable']", count: 0
    assert_select "meta[name='mobile-web-app-capable']", count: 0
    assert_select "[data-pwa-install-banner], [data-pwa-open-install]", count: 0
    assert_select "link[data-lawrelay-stylesheet='pwa_install']", count: 0
  end

  test "an unrelated host does not advertise installation" do
    host! "unrelated.example.test"
    get new_session_path(locale: :en)
    assert_response :success
    assert_select "link[rel='manifest'], [data-pwa-install-banner], [data-pwa-open-install]", count: 0
  end
end
