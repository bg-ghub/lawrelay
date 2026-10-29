require "test_helper"
require_relative "../support/marketplace_test_factory"

class SettingsProfileImportTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  setup do
    @account = create_marketplace_account(prefix: "importmember")
    @account.profile.update!(directory_profile_url: PROFILE_URL, directory_name: @account.user.full_name,
      court_preferences: [ "Existing court" ], availability_note: "Existing availability")
    sign_in_as(@account.user)
  end

  test "GET shows a localized import button without fetching the directory" do
    without_fetch do
      %i[nl fr de en].each do |locale|
        get settings_path(locale: locale)
        assert_response :success
        assert_select "button[name='settings_action'][value='import_profile']", text: I18n.t("profile_import.button", locale: locale)
      end
    end
  end

  test "preview uses only the linked profile preserves edits and changes no records or verification" do
    original = records.map(&:attributes)
    expected_name = @account.user.full_name
    calls = []
    with_result(import_result, calls: calls) do
      assert_no_enqueued_jobs do
        assert_no_difference "AuditEvent.count" do
          patch settings_path(locale: :en), params: {
            settings_action: "import_profile", profile_url: "https://evil.example/other",
            account: { first_name: "Unsaved", email_address: "forged@example.test", password: "do-not-change" },
            profile: { availability_note: "Unsaved note", court_preferences: [ "Unsaved court" ], directory_profile_url: "https://evil.example/other", verification_status: "verified" },
            firm: { name: "Unsaved office", phone: "Old phone" }
          }
        end
      end
    end

    assert_response :success
    assert_equal [ { profile_url: PROFILE_URL, full_name: expected_name } ], calls
    assert_select "input[name='account[first_name]'][value='Unsaved']"
    assert_select "textarea[name='profile[availability_note]']", text: "Unsaved note"
    assert_select "input[name='profile[court_preferences][]'][value='Unsaved court']"
    assert_select "input[name='profile[spoken_languages][]'][value='NL, FR']"
    assert_select "input[name='firm[name]'][value='Unsaved office']"
    assert_select "input[name='firm[phone]'][value='+3225550101']"
    assert_equal original, records.map { |record| record.reload.attributes }
  end

  test "ordinary members cannot import shared firm attributes" do
    @account.user.memberships.first.update!(role: "member")
    original = @account.firm.attributes
    with_result(import_result) do
      patch settings_path(locale: :en), params: { settings_action: "import_profile", firm: { phone: "Forged" } }
    end
    assert_response :success
    assert_select "input[name='firm[phone]']", count: 0
    assert_equal original, @account.firm.reload.attributes
  end

  test "failed fetch keeps unsaved values and persisted records unchanged" do
    original = records.map(&:attributes)
    result = Directory::ProfileImport::Result.new(status: :unavailable, profile_attributes: {}, firm_attributes: {})
    with_result(result) do
      patch settings_path(locale: :en), params: { settings_action: "import_profile", profile: { availability_note: "Keep this edit" } }
    end
    assert_response :unprocessable_content
    assert_select "textarea[name='profile[availability_note]']", text: "Keep this edit"
    assert_includes response.body, I18n.t("profile_import.unavailable", locale: :en)
    assert_equal original, records.map { |record| record.reload.attributes }
  end

  test "administrator and unauthenticated requests cannot import a profile" do
    @account.user.update!(system_role: "admin")
    without_fetch do
      get settings_path(locale: :en)
      assert_select "button[value='import_profile']", count: 0
      patch settings_path(locale: :en), params: { settings_action: "import_profile" }
      assert_response :forbidden
      sign_out
      patch settings_path(locale: :en), params: { settings_action: "import_profile" }
      assert_redirected_to new_session_path(locale: :en)
    end
  end

  private

  def records
    [ @account.user, @account.profile, @account.firm ]
  end

  def import_result
    Directory::ProfileImport::Result.new(status: :ok,
      profile_attributes: { spoken_languages: %w[NL FR] },
      firm_attributes: { phone: "+3225550101", address_line_1: "Example Street 10", postal_code: "1000", city: "Brussel" })
  end

  def with_result(result, calls: [])
    original = Directory::ProfileImport.method(:call)
    Directory::ProfileImport.define_singleton_method(:call) do |**arguments|
      calls << arguments
      result
    end
    yield
  ensure
    Directory::ProfileImport.define_singleton_method(:call, original)
  end

  def without_fetch
    original = Directory::ProfileImport.method(:call)
    Directory::ProfileImport.define_singleton_method(:call) { |**| raise "Unexpected directory fetch" }
    yield
  ensure
    Directory::ProfileImport.define_singleton_method(:call, original)
  end
end
