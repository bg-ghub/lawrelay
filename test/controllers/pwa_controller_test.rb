require "test_helper"

class PwaControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_environment = ENV.slice("APP_HOST", "ADMIN_HOST")
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["ADMIN_HOST"] = "admin.lawrelay.example"
    host! "lawrelay.example"
  end

  teardown do
    %w[APP_HOST ADMIN_HOST].each do |key|
      @previous_environment.key?(key) ? ENV[key] = @previous_environment[key] : ENV.delete(key)
    end
  end

  test "localized manifests share one application identity and use the selected locale" do
    %i[nl fr de en].each do |locale|
      get pwa_manifest_path(locale: locale)

      assert_response :success
      assert_equal "application/manifest+json", response.media_type
      manifest = response.parsed_body
      manifest = JSON.parse(response.body) unless manifest.is_a?(Hash)
      assert_equal "/", manifest.fetch("id")
      assert_equal "/", manifest.fetch("scope")
      assert_equal "/#{locale}", manifest.fetch("start_url")
      assert_equal locale.to_s, manifest.fetch("lang")
      assert_equal "LawRelay", manifest.fetch("name")
      assert_equal "LawRelay", manifest.fetch("short_name")
      assert_equal "standalone", manifest.fetch("display")
      assert_equal I18n.t("marketing.layout.description", locale: locale), manifest.fetch("description")
      assert_equal "#173f3b", manifest.fetch("theme_color")
      assert_equal "#f6f1e8", manifest.fetch("background_color")
      assert_equal [ "192x192", "512x512", "512x512" ], manifest.fetch("icons").map { |icon| icon.fetch("sizes") }
      assert_equal "maskable", manifest.fetch("icons").last.fetch("purpose")
      assert_equal "/pwa-icon-maskable-512.png", manifest.fetch("icons").last.fetch("src")
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
      assert_nil response.headers["Set-Cookie"]
      assert_not_includes response.body, "<html"
    end
  end

  test "the unprefixed manifest uses the default locale without personalizing it" do
    get "/manifest.webmanifest"

    assert_response :success
    assert_equal "/#{I18n.default_locale}", JSON.parse(response.body).fetch("start_url")
  end

  test "metadata remains public when the geographic challenge is enabled" do
    original_enabled = GeoCountry.method(:challenge_enabled?)
    original_country = GeoCountry.method(:country_for)
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }

    get pwa_manifest_path(locale: :en)
    assert_response :success
    assert_nil response.headers["Location"]
    get pwa_service_worker_path
    assert_response :success
    assert_nil response.headers["Location"]
  ensure
    GeoCountry.define_singleton_method(:challenge_enabled?, original_enabled) if original_enabled
    GeoCountry.define_singleton_method(:country_for, original_country) if original_country
  end

  test "service worker supports the root scope without intercepting or storing requests" do
    get pwa_service_worker_path

    assert_response :success
    assert_equal "application/javascript", response.media_type
    assert_equal "/", response.headers["Service-Worker-Allowed"]
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_nil response.headers["Set-Cookie"]
    assert_includes response.body, 'addEventListener("install"'
    assert_includes response.body, 'addEventListener("activate"'
    refute_match(/\bcaches\b|CacheStorage|\bfetch\s*\(|addEventListener\(["'](?:fetch|push|notificationclick)/, response.body)
  end

  test "administrator and unrelated hosts cannot serve installable app metadata" do
    [ "admin.lawrelay.example", "www.lawrelay.example", "unrelated.example" ].each do |hostname|
      host! hostname
      [ pwa_service_worker_path, pwa_manifest_path(locale: :en) ].each do |path|
        get path
        assert_response :not_found
        assert_empty response.body
        assert_nil response.headers["Location"]
      end
    end
  end

  test "metadata accepts HEAD but no state-changing methods" do
    head pwa_manifest_path(locale: :fr)
    assert_response :success
    assert_empty response.body

    head pwa_service_worker_path
    assert_response :success
    assert_empty response.body

    post pwa_service_worker_path
    assert_response :not_found
  end
end
