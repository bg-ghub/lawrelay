require "test_helper"
require_relative "../support/marketplace_test_factory"

class SettingsPreferencesTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  setup do
    @account = create_marketplace_account(prefix: "preferences")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_profile_id: SecureRandom.uuid, directory_name: @account.user.full_name,
      directory_email: @account.user.email_address, directory_checked_at: Time.current,
      directory_email_verified_at: Time.current, directory_professional_address: "Example Street 10, 1000 Brussels",
      directory_bar_name: "Example Bar", spoken_languages: [ "NL" ], practice_areas: [ "Commercial law" ])
    sign_in_as(@account.user)
  end

  test "members save their admission year and ignore removed fields without another identity check" do
    @account.user.memberships.first.update!(role: "member")
    @account.profile.update!(court_preferences: [ "Existing court" ], availability_note: "Existing note")
    original = @account.profile.attributes.except("bar_admission_year", "updated_at")

    assert_difference "AuditEvent.count", 1 do
      assert_no_enqueued_jobs do
        assert_no_enqueued_emails do
          patch settings_path(locale: :en), params: { preferences: {
            bar_admission_year: "2018", court_preferences: [ "", " Gent ", "Gent", "Antwerpen" ],
            availability_note: " Tuesday mornings. "
          } }
        end
      end
    end

    assert_redirected_to settings_path(locale: :en)
    profile = @account.profile.reload
    assert_equal 2018, profile.bar_admission_year
    assert_equal [ "Existing court" ], profile.court_preferences
    assert_equal "Existing note", profile.availability_note
    assert_equal original, profile.attributes.except("bar_admission_year", "updated_at")
    assert_predicate @account.user.reload, :marketplace_verified?
    event = AuditEvent.order(:id).last
    assert_equal profile, event.auditable
    assert_equal false, event.metadata.fetch("profile_requires_review")
    assert_includes event.metadata.fetch("changed_fields"), "bar_admission_year"
    assert_not_includes event.metadata.fetch("changed_fields"), "court_preferences"
    assert_not_includes event.metadata.fetch("changed_fields"), "availability_note"
  end

  test "members can clear their admission year without clearing retained historical fields" do
    @account.profile.update!(bar_admission_year: 2018, court_preferences: [ "Gent" ], availability_note: "Tuesdays")

    patch settings_path(locale: :en), params: { preferences: {
      bar_admission_year: "", court_preferences: [ "" ], availability_note: ""
    } }

    assert_redirected_to settings_path(locale: :en)
    assert_nil @account.profile.reload.bar_admission_year
    assert_equal [ "Gent" ], @account.profile.court_preferences
    assert_equal "Tuesdays", @account.profile.availability_note
  end

  test "invalid admission year rolls back account and profile changes" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes

    assert_no_difference "AuditEvent.count" do
      assert_no_enqueued_jobs do
        patch settings_path(locale: :en), params: { account: { first_name: "Changed", locale: "fr" },
          preferences: { bar_admission_year: Time.current.year + 1, availability_note: "Should not persist" } }
      end
    end

    assert_response :unprocessable_content
    assert_select ".form-error", count: 1
    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, @account.profile.reload.attributes
  end

  test "removed courts and availability parameters cannot change stored fields" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes

    [ { court_preferences: (1..51).map { |i| "Court #{i}" } },
      { court_preferences: [ "x" * 181 ] },
      { availability_note: "x" * 501 } ].each do |preferences|
      assert_no_difference "AuditEvent.count" do
        assert_no_enqueued_jobs do
          patch settings_path(locale: :en), params: { preferences: preferences }
        end
      end
      assert_redirected_to settings_path(locale: :en)
      assert_equal original_user, @account.user.reload.attributes
      assert_equal original_profile, @account.profile.reload.attributes
    end
  end

  test "tampered preferences cannot edit another profile or imported and verification fields" do
    other = create_marketplace_account(prefix: "preferences-other")
    other_attributes = other.profile.attributes
    protected_attributes = @account.profile.attributes.except("bar_admission_year", "updated_at")

    patch settings_path(locale: :en), params: {
      preferences: { id: other.profile.id, user_id: other.user.id, bar_admission_year: 2010,
        verification_status: "suspended", verified_at: nil, bar_number: "forged", directory_name: "forged",
        directory_email: "forged@example.test", directory_professional_address: "forged", spoken_languages: [ "DE" ], practice_areas: [ "forged" ] },
      profile: { availability_note: "Retired namespace", directory_bar_name: "forged" }
    }

    assert_redirected_to settings_path(locale: :en)
    assert_equal 2010, @account.profile.reload.bar_admission_year
    assert_equal protected_attributes, @account.profile.attributes.except("bar_admission_year", "updated_at")
    assert_equal other_attributes, other.profile.reload.attributes
  end

  test "administrator profiles have no optional editor and ignore forged preferences" do
    @account.user.update!(system_role: "admin")
    original = @account.profile.attributes
    get settings_path(locale: :en)
    assert_response :success
    assert_select "[name^='preferences[']", count: 0

    assert_no_difference "AuditEvent.count" do
      patch settings_path(locale: :en), params: { preferences: { bar_admission_year: 2010,
        court_preferences: [ "Gent" ], availability_note: "Unavailable" } }
    end
    assert_redirected_to settings_path(locale: :en)
    assert_equal original, @account.profile.reload.attributes
  end

  test "malformed preference groups fail without changing the account" do
    before = @account.profile.attributes
    assert_no_difference "AuditEvent.count" do
      patch settings_path(locale: :en), params: { preferences: "invalid", account: { locale: "fr" } }
    end
    assert_response :bad_request
    assert_equal before, @account.profile.reload.attributes
    assert_equal "en", @account.user.reload.locale
  end

  test "all languages offer only admission year while directory details stay read only" do
    %i[nl fr de en].each do |locale|
      get settings_path(locale:)
      assert_response :success
      assert_select ".profile-preferences legend", text: I18n.t("settings.preferences.legend", locale:)
      assert_select "input[name='preferences[bar_admission_year]'][max='#{Time.current.year}']"
      assert_select "[name='preferences[court_preferences][]']", count: 0
      assert_select "datalist#preferred-court-options", count: 0
      assert_select "[name='preferences[availability_note]']", count: 0
      assert_select "input[name^='profile['], textarea[name^='profile[']", count: 0
      assert_select "input[name='account[first_name]'], input[name='account[last_name]']", count: 0
      assert_select "a[href^='mailto:support@lawrelay.be']", text: I18n.t("email_change.link", locale:)
      assert_select "a[href='#{email_change_path(locale:)}']", count: 0
      assert_select ".directory-profile__tag", text: I18n.t("marketplace.practice_areas.commercial", locale:)
      assert_not_includes response.body, "translation missing"
    end
  end
end
