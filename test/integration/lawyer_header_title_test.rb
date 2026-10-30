require "test_helper"
require_relative "../support/marketplace_test_factory"

class LawyerHeaderTitleTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  TITLES = { nl: "mr.", fr: "Me", de: "RA", en: "Adv." }.freeze

  test "the selected page language determines the lawyer title without changing their name" do
    account = create_marketplace_account(prefix: "headertitle")
    original_name = account.user.attributes.slice("first_name", "last_name")

    TITLES.each do |locale, title|
      preferred_locale = locale == :nl ? "fr" : "nl"
      account.user.update!(locale: preferred_locale)
      sign_in_as(account.user)

      get privacy_path(locale:)

      assert_response :success
      assert_select "html[lang='#{locale}']"
      assert_select ".site-header a.header-login[href='#{settings_path(locale:)}']", text: "#{title} #{account.user.full_name}"
      assert_equal preferred_locale, account.user.reload.locale
      assert_equal original_name, account.user.attributes.slice("first_name", "last_name")
    end
  end

  test "administrators retain an untitled name in every public page language" do
    account = create_marketplace_account(prefix: "admintitle", system_role: "admin")

    TITLES.each_key do |locale|
      account.user.update!(locale: locale == :nl ? "fr" : "nl")
      sign_in_as(account.user)

      get privacy_path(locale:)

      assert_response :success
      assert_select ".site-header a.header-login[href='#{admin_users_path(locale:)}']", text: account.user.full_name
    end
  end
end
