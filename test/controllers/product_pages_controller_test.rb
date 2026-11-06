require "test_helper"
require_relative "../support/marketplace_test_factory"

class ProductPagesControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  self.fixture_table_names = []

  PAGES = { court_cover: "court-cover", legal_assignments: "legal-assignments" }.freeze

  setup do
    @original_geo_enabled = GeoCountry.method(:challenge_enabled?)
    @original_country = GeoCountry.method(:country_for)
    @original_google = VerifiedGoogleCrawler.method(:call)
    GeoCountry.define_singleton_method(:challenge_enabled?) { false }
  end

  teardown do
    GeoCountry.define_singleton_method(:challenge_enabled?, @original_geo_enabled)
    GeoCountry.define_singleton_method(:country_for, @original_country)
    VerifiedGoogleCrawler.define_singleton_method(:call, @original_google)
  end

  test "all eight public pages have localized copy metadata actions and language links without member data" do
    private_account = create_marketplace_account(prefix: "private-product-member")
    assignment = create_assignment_for(private_account, title: "Private product-page assignment")

    %i[nl fr de en].each do |locale|
      PAGES.each do |page, slug|
        path = public_send("#{page}_path", locale:)
        assert_equal "/#{locale}/#{slug}", path
        get path

        assert_response :success
        assert_select "html[lang='#{locale}']"
        assert_select "title", text: I18n.t("product_pages.#{page}.meta_title", locale:)
        assert_select "meta[name='description'][content=?]", I18n.t("product_pages.#{page}.meta_description", locale:)
        assert_select "meta[name='robots'][content='index,follow']"
        assert_select "link[rel='canonical'][href$='#{path}']"
        assert_select ".product-page h1", text: I18n.t("product_pages.#{page}.heading", locale:)
        assert_select ".product-example h2", text: I18n.t("product_pages.example.label", locale:)
        assert_select ".product-example__request strong", text: I18n.t("product_pages.#{page}.example.title", locale:)
        assert_select ".product-example__offer p", text: I18n.t("product_pages.#{page}.example.reply", locale:)
        assert_select ".product-example a, .product-example button, .product-example form", count: 0
        assert_select ".product-page__actions a[href='#{new_assignment_path(locale:)}']"
        assert_select ".product-page__actions a[href='#{assignments_path(locale:)}']"
        assert_select ".product-page__actions a[href='#{new_registration_path(locale:)}']"
        assert_select ".product-page__actions a[href='#{new_session_path(locale:)}']"
        other_page = (PAGES.keys - [ page ]).first
        assert_select ".product-page__related a[href='#{public_send("#{other_page}_path", locale:)}']"
        (%i[nl fr de en] - [ locale ]).each do |alternate|
          assert_select ".language-menu a[hreflang='#{alternate}'][href='#{public_send("#{page}_path", locale: alternate)}']"
        end
        words = Nokogiri::HTML(response.body).at_css(".product-page").text.squish.split.size
        assert_operator words, :<=, 220, "#{locale}/#{page} including its example should stay concise"
        assert_not_includes response.body, assignment.title
        assert_not_includes response.body, private_account.user.full_name
        assert_not_includes response.body, private_account.user.email_address
        assert_no_match(/translation missing/i, response.body)
      end
    end
  end

  test "the homepage and footer expose localized product links" do
    %i[nl fr de en].each do |locale|
      get root_path(locale:)
      assert_response :success
      PAGES.each_key do |page|
        path = public_send("#{page}_path", locale:)
        assert_select "#how-it-works .product-page-links a[href='#{path}']"
        assert_select ".site-footer a[href='#{path}']"
      end
      assert_select ".pathway-card a", count: 0
    end
  end

  test "the beta sitemap contains the 28 translated public URLs and no private application paths" do
    original_mode = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = "beta"
    get "/sitemap.xml"

    assert_response :success
    urls = Nokogiri::XML(response.body).xpath("//s:url/s:loc", "s" => "http://www.sitemaps.org/schemas/sitemap/0.9").map(&:text)
    assert_equal 28, urls.size
    assert_equal 28, urls.uniq.size
    %i[nl fr de en].each do |locale|
      PAGES.each_key { |page| assert urls.any? { |url| URI(url).path == public_send("#{page}_path", locale:) } }
    end
    assert_not urls.any? { |url| URI(url).path.match?(%r{/(?:admin|settings|assignments|dashboard|registration|pricing)(?:/|$)}) }
  ensure
    original_mode.nil? ? ENV.delete("LAWRELAY_RELEASE_MODE") : ENV["LAWRELAY_RELEASE_MODE"] = original_mode
  end

  test "foreign unverified crawlers are challenged on both new public pages" do
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
    GeoCountry.define_singleton_method(:country_for) { |_| "US" }
    VerifiedGoogleCrawler.define_singleton_method(:call) { |**| false }

    PAGES.each_key do |page|
      get public_send("#{page}_path", locale: :fr), headers: { "User-Agent" => "Googlebot/2.1" }
      assert_redirected_to geo_challenge_path(locale: :fr)
    end
  end

  test "Belgian visitors and verified Google crawlers can read the product pages without private access" do
    GeoCountry.define_singleton_method(:challenge_enabled?) { true }
    [ "BE", "US" ].each do |country|
      GeoCountry.define_singleton_method(:country_for) { |_| country }
      VerifiedGoogleCrawler.define_singleton_method(:call) { |**| country == "US" }
      PAGES.each_key do |page|
        get public_send("#{page}_path", locale: :de), headers: { "User-Agent" => "Google-InspectionTool/1.0" }
        assert_response :success
        assert_nil cookies[:geo_verified]
      end
    end
    get assignments_path(locale: :de), headers: { "User-Agent" => "Google-InspectionTool/1.0" }
    assert_redirected_to new_session_path(locale: :de)
  end
end
