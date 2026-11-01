require "test_helper"
require_relative "../support/marketplace_test_factory"

class LanguagePreferencesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "locale-preference")
    @other = create_marketplace_account(prefix: "other-locale-preference")
  end

  test "an explicit header choice changes only the authenticated account locale" do
    sign_in_as(@account.user)

    patch language_preference_path(locale: :en), params: { preferred_locale: "fr", user_id: @other.user.id }

    assert_response :no_content
    assert_equal "fr", @account.user.reload.locale
    assert_equal "en", @other.user.reload.locale
    get settings_path(locale: :fr)
    assert_select "select[name='account[locale]'] option[value='fr'][selected]"
    assert_select ".language-menu[data-language-menu-preference-url-value='#{language_preference_path(locale: :fr)}']"
  end

  test "viewing a translated page does not change the account preference" do
    sign_in_as(@account.user)

    get settings_path(locale: :nl)

    assert_response :success
    assert_equal "en", @account.user.reload.locale
  end

  test "invalid locale choices do not mutate the preference" do
    sign_in_as(@account.user)
    [ "es", "", { locale: "fr" }, [ "fr" ] ].each do |value|
      patch language_preference_path(locale: :en), params: { preferred_locale: value }

      assert_response :unprocessable_content
      assert_equal "en", @account.user.reload.locale
    end
  end

  test "anonymous visitors retain read-only language links and cannot update preferences" do
    get root_path(locale: :en), params: { q: "Synthetic & query" }
    assert_response :success
    assert_select ".language-menu[data-language-menu-preference-url-value='']"
    assert_select ".language-menu a[hreflang='fr'][href='#{root_path(locale: :fr, q: "Synthetic & query")}']"

    patch language_preference_path(locale: :en), params: { preferred_locale: "fr" }

    assert_redirected_to new_session_path(locale: :en)
    assert_equal "en", @account.user.reload.locale
  end

  test "a missing CSRF token cannot change the preference" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    sign_in_as(@account.user)

    patch language_preference_path(locale: :en), params: { preferred_locale: "fr" }

    assert_response :unprocessable_content
    assert_equal "en", @account.user.reload.locale
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  test "the admin portal permits its administrator locale choice without changing a member" do
    original_environment = ENV.slice("APP_HOST", "ADMIN_HOST", "APP_PROTOCOL")
    ENV["APP_HOST"] = "lawrelay.example"
    ENV["ADMIN_HOST"] = "admin.lawrelay.example"
    ENV["APP_PROTOCOL"] = "https"
    host! "admin.lawrelay.example"
    https!
    admin = create_marketplace_account(prefix: "locale-admin", system_role: "admin").user
    sign_in_as(admin)

    patch language_preference_path(locale: :en), params: { preferred_locale: "de" }

    assert_response :no_content
    assert_equal "de", admin.reload.locale
    assert_equal "en", @account.user.reload.locale

    sign_in_as(@account.user)
    patch language_preference_path(locale: :en), params: { preferred_locale: "nl" }
    assert_response :forbidden
    assert_equal "en", @account.user.reload.locale
  ensure
    %w[APP_HOST ADMIN_HOST APP_PROTOCOL].each do |key|
      original_environment.key?(key) ? ENV[key] = original_environment[key] : ENV.delete(key)
    end
  end
end
