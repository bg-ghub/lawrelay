require "test_helper"
require_relative "../support/marketplace_test_factory"

class SettingsProfileImportTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  setup do
    @account = create_marketplace_account(prefix: "importmember")
    @account.profile.update!(directory_profile_url: PROFILE_URL, directory_name: @account.user.full_name,
      directory_email: "directory@advocaat.be",
      directory_professional_address: "Example Street 10, 1000 Brussels", directory_bar_name: "Example Bar",
      spoken_languages: [ "NL" ], practice_areas: [ "Existing area" ], court_preferences: [ "Existing court" ],
      availability_note: "Existing availability")
    sign_in_as(@account.user)
  end

  test "GET shows a localized refresh button without fetching the directory or editable profile fields" do
    without_sync do
      %i[nl fr de en].each do |locale|
        get settings_path(locale: locale)
        assert_response :success
        assert_select "button[name='settings_action'][value='refresh_profile']", text: I18n.t("profile_import.button", locale: locale)
        assert_select "input[name^='profile['], textarea[name^='profile[']", count: 0
        assert_select ".field-hint", text: I18n.t("profile_import.scope", locale: locale)
        assert_includes response.body, I18n.t("profile_import.manual_hint", locale: locale)
        assert_select ".directory-profile__support a[href='mailto:support@lawrelay.be']", text: I18n.t("profile_import.contact_support", locale: locale)
        assert_select ".advocaat-webmail-hint a[href='https://webmail.advocaat.be/']", text: "webmail.advocaat.be"
      end
    end
  end

  test "GET shows the read-only directory source data with localized language labels" do
    without_sync do
      %i[nl fr de en].each do |locale|
        get settings_path(locale: locale)
        assert_response :success

        assert_select ".directory-profile__data" do
          assert_select "dt", text: I18n.t("profile_import.fields.name", locale: locale)
          assert_select "dd", text: @account.profile.directory_name
          assert_select "dt", text: I18n.t("profile_import.fields.email", locale: locale)
          assert_select ".directory-profile__email", text: "directory@advocaat.be"
          assert_select "dt", text: I18n.t("directory_location.bar", locale: locale)
          assert_select "dd", text: "Example Bar"
          assert_select "dt", text: I18n.t("directory_location.address", locale: locale)
          assert_select "dd", text: "Example Street 10, 1000 Brussels"
          assert_select "dt", text: I18n.t("settings.profile.languages", locale: locale)
          assert_select "li.directory-profile__tag", text: I18n.t("profile_import.language_names.nl", locale: locale)
          assert_select "dt", text: I18n.t("settings.profile.practice_areas", locale: locale)
          assert_select "li.directory-profile__tag", text: "Existing area"
        end
        assert_select ".directory-profile", text: /#{Regexp.escape(I18n.t("profile_import.source", locale: locale))}/
        assert_select ".directory-profile__data", count: 1 do
          assert_select "dd", text: @account.user.email_address, count: 0
        end
      end
    end
  end

  test "GET renders all imported language labels in the selected locale" do
    @account.profile.update!(spoken_languages: %w[NL FR DE EN])

    %i[nl fr de en].each do |locale|
      get settings_path(locale: locale)
      assert_response :success
      %i[nl fr de en].each do |language|
        assert_select ".directory-profile__data li.directory-profile__tag", text: I18n.t("profile_import.language_names.#{language}", locale: locale)
      end
    end
  end

  test "GET renders explicit localized empty values" do
    @account.profile.update!(directory_name: nil, directory_email: nil, spoken_languages: [], practice_areas: [],
      directory_professional_address: nil, directory_bar_name: nil)

    %i[nl fr de en].each do |locale|
      get settings_path(locale: locale)
      assert_response :success
      assert_select ".directory-profile__data" do
        assert_select "dd", text: /#{Regexp.escape(I18n.t("profile_import.not_available", locale: locale))}/, count: 6
      end
    end
  end

  test "GET escapes imported source data" do
    @account.profile.update!(directory_name: "<strong>Directory name</strong>", directory_email: "<script>alert@example.test</script>")

    get settings_path(locale: :en)
    assert_response :success
    assert_select ".directory-profile__data dd", text: "<strong>Directory name</strong>"
    assert_select ".directory-profile__data dd", text: "<script>alert@example.test</script>"
    assert_select ".directory-profile__data dd strong, .directory-profile__data dd script", count: 0
    assert_includes response.body, "&lt;strong&gt;Directory name&lt;/strong&gt;"
    assert_includes response.body, "&lt;script&gt;alert@example.test&lt;/script&gt;"
  end

  test "GET keeps the source card email separate from the account email" do
    get settings_path(locale: :en)
    assert_response :success
    assert_select ".directory-profile__email", text: "directory@advocaat.be"
    assert_select ".directory-profile__data dd", text: @account.user.email_address, count: 0
  end

  test "webmail hint only accepts the exact advocaat.be domain" do
    [ " Directory@ADVOCAAT.BE ", "directory@notadvocaat.be", "directory@advocaat.be.evil" ].each do |email|
      @account.profile.update!(directory_email: email)
      get settings_path(locale: :en)
      assert_response :success

      if email.casecmp(" Directory@ADVOCAAT.BE ").zero?
        assert_select ".advocaat-webmail-hint a[href='https://webmail.advocaat.be/']", text: "webmail.advocaat.be"
      else
        assert_select ".advocaat-webmail-hint a[href='https://webmail.advocaat.be/']", count: 0
      end
    end
  end

  test "refresh persists only directory fields and ignores posted account, profile and company values" do
    original_name = @account.user.first_name
    original_firm = @account.firm.attributes
    result = sync_result(:updated, %w[spoken_languages practice_areas])
    calls = []
    with_sync(result, calls:) do
      patch settings_path(locale: :en), params: {
        settings_action: "refresh_profile",
        account: { first_name: "Forged", email_address: "forged@example.test" },
        profile: { availability_note: "Forged note", court_preferences: [ "Forged court" ], verification_status: "verified" },
        firm: { name: "Forged office" }
      }
    end

    assert_redirected_to settings_path(locale: :en)
    assert_equal [ { user: @account.user, actor: @account.user } ], calls
    assert_equal original_name, @account.user.reload.first_name
    assert_equal original_firm, @account.firm.reload.attributes
    assert_equal "Existing availability", @account.profile.reload.availability_note
    assert_equal [ "Existing court" ], @account.profile.court_preferences
    assert_equal I18n.t("profile_import.updated", locale: :en), flash[:notice]
  end

  test "failed refresh preserves stored data and renders a localized error" do
    original = @account.profile.attributes
    with_sync(sync_result(:unavailable, [])) do
      patch settings_path(locale: :en), params: { settings_action: "refresh_profile" }
    end

    assert_response :unprocessable_content
    assert_includes response.body, I18n.t("profile_import.unavailable", locale: :en)
    assert_equal original, @account.profile.reload.attributes
  end

  test "legacy import action remains accepted as a refresh alias" do
    with_sync(sync_result(:unchanged, [])) do
      patch settings_path(locale: :en), params: { settings_action: "import_profile" }
    end
    assert_redirected_to settings_path(locale: :en)
  end

  test "administrator and unauthenticated requests cannot refresh a profile" do
    @account.user.update!(system_role: "admin")
    without_sync do
      get settings_path(locale: :en)
      assert_select "button[value='refresh_profile']", count: 0
      patch settings_path(locale: :en), params: { settings_action: "refresh_profile" }
      assert_response :forbidden
      sign_out
      patch settings_path(locale: :en), params: { settings_action: "refresh_profile" }
      assert_redirected_to new_session_path(locale: :en)
    end
  end

  private

  def sync_result(status, changed_fields)
    result_class = Data.define(:status, :changed_fields) do
      def success? = status.in?(%i[updated unchanged])
    end
    result_class.new(status:, changed_fields:)
  end

  def with_sync(result, calls: [])
    original = Directory::ProfileSync.method(:call)
    Directory::ProfileSync.define_singleton_method(:call) do |**arguments|
      calls << arguments
      result
    end
    yield
  ensure
    Directory::ProfileSync.define_singleton_method(:call, original)
  end

  def without_sync
    original = Directory::ProfileSync.method(:call)
    Directory::ProfileSync.define_singleton_method(:call) { |**| raise "Unexpected directory refresh" }
    yield
  ensure
    Directory::ProfileSync.define_singleton_method(:call, original)
  end
end
