require "test_helper"

class SeoControllerTest < ActionDispatch::IntegrationTest
  setup do
    @original_app_host = ENV["APP_HOST"]
    @original_verification_file = ENV["GOOGLE_SITE_VERIFICATION_FILE"]
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["GOOGLE_SITE_VERIFICATION_FILE"] = "google0123456789abcdef.html"
  end

  teardown do
    ENV["APP_HOST"] = @original_app_host
    ENV["GOOGLE_SITE_VERIFICATION_FILE"] = @original_verification_file
  end

  test "configured Google verification is public exact HTML without a layout" do
    host! "lawrelay.example"
    get "/google0123456789abcdef.html"

    assert_response :success
    assert_equal "text/html; charset=utf-8", response.content_type
    assert_equal "google-site-verification: google0123456789abcdef.html", response.body
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_nil response.headers["Location"]
  end

  test "Google verification supports HEAD without response content" do
    host! "lawrelay.example"
    head "/google0123456789abcdef.html"

    assert_response :success
    assert_equal "text/html; charset=utf-8", response.content_type
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_empty response.body
  end

  test "Google verification remains available when the geographic challenge is enabled" do
    host! "lawrelay.example"
    original_enabled = GeoCountry.method(:challenge_enabled?)
    original_country = GeoCountry.method(:country_for)
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
    GeoCountry.define_singleton_method(:country_for) { |_| nil }
    get "/google0123456789abcdef.html"

    assert_response :success
    assert_equal "google-site-verification: google0123456789abcdef.html", response.body
  ensure
    GeoCountry.define_singleton_method(:challenge_enabled?, original_enabled) if original_enabled
    GeoCountry.define_singleton_method(:country_for, original_country) if original_country
  end

  test "Google verification is unavailable without configuration" do
    host! "lawrelay.example"
    ENV.delete("GOOGLE_SITE_VERIFICATION_FILE")
    get "/google0123456789abcdef.html"

    assert_response :not_found
    assert_empty response.body
  end

  test "Google verification rejects a different filename" do
    host! "lawrelay.example"
    get "/googlefedcba9876543210.html"

    assert_response :not_found
    assert_not_includes response.body, "google-site-verification:"
  end

  test "Google verification uses only the current configured filename" do
    host! "lawrelay.example"
    ENV["GOOGLE_SITE_VERIFICATION_FILE"] = "googlefedcba9876543210.html"
    get "/googlefedcba9876543210.html"

    assert_response :success
    assert_equal "google-site-verification: googlefedcba9876543210.html", response.body

    get "/google0123456789abcdef.html"
    assert_response :not_found
  end

  test "Google verification rejects invalid configuration instead of reading a file" do
    host! "lawrelay.example"
    [ "../config/master.key", "google0123456789abcdef.html\r\n", "google0123456789abcdeg.html",
      "google0123456789abcde.html", "google0123456789ABCDEF.html" ].each do |filename|
      ENV["GOOGLE_SITE_VERIFICATION_FILE"] = filename
      get "/google0123456789abcdef.html"

      assert_response :not_found
      assert_not_includes response.body, "google-site-verification:"
    end
  end

  test "Google verification is unavailable on the administrator or alias host" do
    [ "admin.lawrelay.example", "www.lawrelay.example", "unrelated.example" ].each do |hostname|
      host! hostname
      get "/google0123456789abcdef.html"

      assert_response :not_found
      assert_empty response.body
    end
  end

  test "Google verification route does not accept write methods or nested paths" do
    host! "lawrelay.example"
    post "/google0123456789abcdef.html"
    assert_response :not_found

    get "/nl/google0123456789abcdef.html"
    assert_response :not_found
  end

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
    assert_not_includes response.body, "/pricing"
    assert_includes response.body, "http://lawrelay.example/fr/legal-notice"
    assert_includes response.body, "http://lawrelay.example/en/terms"
    assert_not_includes response.body, "/assignments"
  end

  test "public pages have canonical and alternate language links" do
    get "/fr/privacy"

    assert_response :success
    assert_select "meta[name='robots'][content='index,follow']"
    assert_select "link[rel='canonical'][href$='/fr/privacy']"
    assert_select "link[rel='alternate'][hreflang='nl'][href$='/nl/privacy']"
    assert_select "link[rel='alternate'][hreflang='x-default'][href$='/en/privacy']"
  end

  test "application pages remain noindex" do
    get "/en/session/new"

    assert_response :success
    assert_select "meta[name='robots'][content='noindex,nofollow']"
    assert_select "link[rel='canonical']", false
  end
end
