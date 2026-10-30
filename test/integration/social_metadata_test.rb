require "test_helper"

class SocialMetadataTest < ActionDispatch::IntegrationTest
  %w[nl fr de en].each do |locale|
    test "#{locale} home page has a complete social preview" do
      get "/#{locale}"

      assert_response :success
      assert_select "meta[property='og:type'][content='website']"
      assert_select "meta[property='og:site_name'][content='LawRelay']"
      og_locale = { "nl" => "nl_BE", "fr" => "fr_BE", "de" => "de_BE", "en" => "en_GB" }.fetch(locale)
      assert_select "meta[property='og:locale'][content='#{og_locale}']"
      assert_select "meta[property='og:locale:alternate']", count: 3
      assert_select "meta[property='og:image'][content='https://lawrelay.be/images/social/lawrelay-#{locale}.png']"
      assert_select "meta[property='og:image:secure_url'][content='https://lawrelay.be/images/social/lawrelay-#{locale}.png']"
      assert_select "meta[property='og:image:type'][content='image/png']"
      assert_select "meta[property='og:image:width'][content='1200']"
      assert_select "meta[property='og:image:height'][content='630']"
      assert_select "meta[property='og:image:alt']"
      assert_select "meta[name='twitter:card'][content='summary_large_image']"
      assert_select "meta[name='twitter:image'][content='https://lawrelay.be/images/social/lawrelay-#{locale}.png']"
      assert_select "meta[name='description'][content=?]", I18n.t("marketing.home.og_description", locale:)
    end

    test "#{locale} social preview asset is a 1200 by 630 PNG" do
      image = File.binread(Rails.public_path.join("images/social/lawrelay-#{locale}.png"), 24)

      assert_equal "\x89PNG\r\n\x1A\n".b, image[0, 8]
      assert_equal [ 1200, 630 ], image[16, 8].unpack("N2")
    end
  end
end
