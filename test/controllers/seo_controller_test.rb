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
    urls = Nokogiri::XML(response.body).xpath("//s:url/s:loc", "s" => "http://www.sitemaps.org/schemas/sitemap/0.9").map(&:text)
    public_paths = [ "", "/privacy", "/terms", "/cookies", "/legal-notice", "/court-cover", "/legal-assignments" ]
    expected = I18n.available_locales.flat_map do |locale|
      public_paths.map { |path| "http://lawrelay.example/#{locale}#{path}" }
    end
    assert_equal 28, urls.length
    assert_equal expected.sort, urls.sort
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

  test "HTML and query variants canonicalize to the clean localized page on a QA host and port" do
    host! "seo.qa.localhost:3108"

    [ "/fr/privacy.html?utm_source=synthetic&q=private", "/fr/privacy?utm_source=synthetic" ].each do |path|
      get path

      assert_response :success
      assert_select "link[rel='canonical'][href='http://seo.qa.localhost:3108/fr/privacy']", count: 1
      I18n.available_locales.each do |locale|
        assert_select "link[rel='alternate'][hreflang='#{locale}'][href='http://seo.qa.localhost:3108/#{locale}/privacy']", count: 1
      end
      assert_select "link[rel='alternate'][hreflang='x-default'][href='http://seo.qa.localhost:3108/en/privacy']", count: 1
    end

    get "/nl.html?utm_source=synthetic"
    assert_response :success
    assert_select "link[rel='canonical'][href='http://seo.qa.localhost:3108/nl']", count: 1
  end

  test "production canonical URLs use the configured main host and protocol instead of request origin" do
    environment = Rails.env
    original_production = environment.method(:production?)
    original_geo = GeoCountry.method(:challenge_enabled?)
    original_protocol = ENV["APP_PROTOCOL"]
    environment.define_singleton_method(:production?) { true }
    GeoCountry.define_singleton_method(:challenge_enabled?) { false }
    ENV["APP_PROTOCOL"] = "https"
    host! "alias.example:3108"

    get "/fr/privacy.html?utm_source=synthetic"

    assert_response :success
    assert_select "link[rel='canonical'][href='https://lawrelay.example/fr/privacy']", count: 1
    I18n.available_locales.each do |locale|
      assert_select "link[rel='alternate'][hreflang='#{locale}'][href='https://lawrelay.example/#{locale}/privacy']", count: 1
    end
  ensure
    environment.define_singleton_method(:production?, original_production) if original_production
    GeoCountry.define_singleton_method(:challenge_enabled?, original_geo) if original_geo
    ENV["APP_PROTOCOL"] = original_protocol
  end

  test "legal pages have distinct factual descriptions in every interface language" do
    host! "lawrelay.example"
    pages = { "privacy" => "privacy", "terms" => "terms", "cookies" => "cookies", "legal-notice" => "legal_notice" }
    descriptions = []
    I18n.available_locales.each do |locale|
      pages.each do |path, key|
        get "/#{locale}/#{path}"

        assert_response :success
        description = I18n.t("pages.#{key}.meta_description", locale:, raise: true)
        assert description.present?
        assert_operator description.length, :<=, 160
        assert_includes description, "LawRelay"
        assert_not_equal I18n.t("marketing.layout.description", locale:), description
        assert_equal description, css_select("meta[name='description']").sole["content"]
        assert_equal description, css_select("meta[property='og:description']").sole["content"]
        descriptions << description
      end
    end
    assert_equal 16, descriptions.uniq.length
  end

  test "localized main homepages publish nonce protected Organization data with the existing public logo" do
    host! "lawrelay.example"
    https!
    I18n.available_locales.each do |locale|
      get "/#{locale}?utm_source=synthetic"

      assert_response :success
      script = css_select("script[type='application/ld+json']").sole
      schema = JSON.parse(script.content)
      assert_equal "https://schema.org", schema.fetch("@context")
      assert_equal "Organization", schema.fetch("@type")
      assert_equal "LawRelay", schema.fetch("name")
      assert_equal "https://lawrelay.example/", schema.fetch("url")
      assert_equal({ "@type" => "ImageObject", "url" => "https://lawrelay.example/icon.png", "width" => 512, "height" => 512 }, schema.fetch("logo"))
      assert_equal %w[@context @type logo name url], schema.keys.sort
      assert script["nonce"].present?
      assert_includes response.headers.fetch("Content-Security-Policy"), "'nonce-#{script['nonce']}'"
    end
  end

  test "Organization data is absent on legal private administrator and alias pages" do
    host! "lawrelay.example"
    [ "/nl/privacy", "/fr/terms", "/de/cookies", "/en/legal-notice", "/nl/session/new" ].each do |path|
      get path
      assert_response :success
      assert_select "script[type='application/ld+json']", false
    end

    host! SiteHosts.admin_host
    get "/nl/admin/login"
    assert_response :success
    assert_select "script[type='application/ld+json']", false

    host! "www.lawrelay.example"
    get "/nl"
    assert_response :success
    assert_select "script[type='application/ld+json']", false
  end

  test "Organization JSON escapes HTML even when the JSON encoder does not" do
    original_schema = ApplicationHelper.instance_method(:homepage_organization_schema)
    original_json_setting = ActiveSupport.escape_html_entities_in_json
    synthetic_name = "Synthetic </script><script data-schema-injection>alert(1)</script>"
    ApplicationHelper.define_method(:homepage_organization_schema) do
      { "@context" => "https://schema.org", "@type" => "Organization", "name" => synthetic_name }
    end
    ActiveSupport.escape_html_entities_in_json = false
    host! "lawrelay.example"

    get "/nl"

    assert_response :success
    script = css_select("script[type='application/ld+json']").sole
    assert_equal synthetic_name, JSON.parse(script.content).fetch("name")
    assert_not_includes script.content, "</script>"
    assert_select "script[data-schema-injection]", false
  ensure
    ApplicationHelper.define_method(:homepage_organization_schema, original_schema) if original_schema
    ActiveSupport.escape_html_entities_in_json = original_json_setting
  end

  test "the Organization logo is a public indexable 512 pixel PNG" do
    host! "lawrelay.example"
    get "/icon.png"

    assert_response :success
    assert_equal "image/png", response.media_type
    assert_nil response.headers["Location"]
    refute_match(/noindex/i, response.headers["X-Robots-Tag"].to_s)
    assert_equal "\x89PNG\r\n\x1a\n".b, response.body.b.byteslice(0, 8)
    assert_equal [ 512, 512 ], response.body.b.byteslice(16, 8).unpack("NN")
  end
end
