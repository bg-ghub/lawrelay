require "test_helper"

class ProductBarTest < ActionDispatch::IntegrationTest
  PRODUCTS = {
    nl: [ "WetWijzer", "https://wetwijzer.be/", "https://praxislegal.be/" ],
    fr: [ "LisLoi", "https://lisloi.be/", "https://praxislegal.be/fr/" ],
    de: [ "GesetzGuide", "https://gesetzguide.be/", "https://praxislegal.be/de/" ],
    en: [ "LexLibera", "https://lexlibera.be/", "https://praxislegal.be/en/" ]
  }.freeze

  test "product bar precedes navigation and links to the corresponding language" do
    PRODUCTS.each do |locale, (research_name, research_url, praxis_url)|
      [ root_path(locale:), new_session_path(locale:) ].each do |path|
        get path

        assert_response :success
        assert_select "nav.product-bar[aria-label='#{I18n.t('products.navigation_label', locale:)}']", count: 1 do
          assert_select ".product-bar__label", text: I18n.t("products.label", locale:)
          assert_select "a[href='#{research_url}'][hreflang='#{locale}'][target='_blank'][rel='noopener noreferrer']", text: research_name
          assert_select "a[href='#{praxis_url}'][hreflang='#{locale}'][target='_blank'][rel='noopener noreferrer']", text: "Praxis"
          assert_select "a", count: 2
        end
        assert_select "nav.product-bar + header.site-header", count: 1
      end
    end
  end
end
