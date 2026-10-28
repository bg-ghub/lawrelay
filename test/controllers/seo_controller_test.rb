require "test_helper"

class SeoControllerTest < ActionDispatch::IntegrationTest
  test "robots excludes application and account paths and points to the sitemap" do
    host! "lawrelay.example"
    get "/robots.txt"

    assert_response :success
    assert_equal "text/plain; charset=utf-8", response.content_type
    assert_includes response.body, "Disallow: /fr/assignments"
    assert_includes response.body, "Disallow: /en/settings"
    assert_includes response.body, "Sitemap: http://lawrelay.example/sitemap.xml"
  end

  test "sitemap has only the translated public pages" do
    host! "lawrelay.example"
    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml; charset=utf-8", response.content_type
    assert_includes response.body, "http://lawrelay.example/nl/pricing"
    assert_includes response.body, "http://lawrelay.example/fr/legal-notice"
    assert_includes response.body, "http://lawrelay.example/en/terms"
    assert_not_includes response.body, "/assignments"
  end

  test "public pages have canonical and alternate language links" do
    get "/fr/pricing"

    assert_response :success
    assert_select "meta[name='robots'][content='index,follow']"
    assert_select "link[rel='canonical'][href$='/fr/pricing']"
    assert_select "link[rel='alternate'][hreflang='nl'][href$='/nl/pricing']"
    assert_select "link[rel='alternate'][hreflang='x-default'][href$='/en/pricing']"
  end

  test "application pages remain noindex" do
    get "/en/session/new"

    assert_response :success
    assert_select "meta[name='robots'][content='noindex,nofollow']"
    assert_select "link[rel='canonical']", false
  end
end
