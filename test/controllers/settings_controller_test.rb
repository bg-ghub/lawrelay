require "test_helper"
require_relative "../support/marketplace_test_factory"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "settings")
    sign_in_as(@account.user)
  end

  test "shows a signed-in lawyer their settings" do
    get settings_path(locale: :en)

    assert_response :success
    assert_includes response.body, "Keep your details current"
  end

  test "updates account profile and owner-managed firm details with an audit trail" do
    assert_difference "AuditEvent.count", 3 do
      patch settings_path(locale: :en), params: {
        account: { first_name: "Ada", last_name: "Byron", email_address: @account.user.email_address, locale: "fr" },
        profile: { bar_association: "OVB", bar_number: @account.profile.bar_number, professional_email: @account.profile.professional_email, bar_admission_year: "2018", spoken_languages: [ "NL, FR" ], practice_areas: [ "Commercial law, Family law" ], court_preferences: [ "Enterprise Court Brussels, Antwerp" ], availability_note: "Tuesday mornings work well." },
        firm: { name: "Settings Legal", enterprise_number: @account.firm.enterprise_number, vat_number: @account.firm.vat_number, billing_email: "billing@example.test", phone: "+32 2 555 01 01", address_line_1: "Rue du Palais 1", postal_code: "1000", city: "Brussels" }
      }
    end

    assert_redirected_to settings_path(locale: :fr)
    @account.user.reload
    @account.profile.reload
    @account.firm.reload
    assert_equal "Ada", @account.user.first_name
    assert_equal "fr", @account.user.locale
    assert_equal [ "NL", "FR" ], @account.profile.spoken_languages
    assert_equal [ "Commercial law", "Family law" ], @account.profile.practice_areas
    assert_equal 2018, @account.profile.bar_admission_year
    assert_equal [ "Enterprise Court Brussels", "Antwerp" ], @account.profile.court_preferences
    assert_equal "Tuesday mornings work well.", @account.profile.availability_note
    assert_equal "Settings Legal", @account.firm.name
    assert_equal "billing@example.test", @account.firm.billing_email
  end

  test "email changes require a new verification and send an email" do
    assert_enqueued_emails 1 do
      patch settings_path(locale: :en), params: valid_params(account: { email_address: "new-address@example.test" })
    end

    assert_redirected_to settings_path(locale: :en)
    @account.user.reload
    assert_equal "new-address@example.test", @account.user.email_address
    assert_nil @account.user.email_verified_at
  end

  test "professional identity changes return the profile and firm to review" do
    patch settings_path(locale: :en), params: valid_params(
      profile: { bar_number: "UPDATED-123" },
      firm: { vat_number: "BE0999999999" }
    )

    @account.profile.reload
    @account.firm.reload
    assert_equal "pending", @account.profile.verification_status
    assert_nil @account.profile.verified_at
    assert_equal "pending", @account.firm.verification_status
    assert_nil @account.firm.verified_at
  end

  test "firm members cannot update firm records" do
    member = create_marketplace_account(prefix: "member")
    member.user.memberships.destroy_all
    member.user.memberships.create!(firm: @account.firm, role: "member")
    sign_in_as(member.user)

    patch settings_path(locale: :en), params: {
      account: { first_name: member.user.first_name, last_name: member.user.last_name, email_address: member.user.email_address, locale: member.user.locale },
      profile: { bar_association: member.profile.bar_association, bar_number: member.profile.bar_number, professional_email: member.profile.professional_email, spoken_languages: member.profile.spoken_languages, practice_areas: member.profile.practice_areas },
      firm: { name: "Not allowed" }
    }

    assert_redirected_to settings_path(locale: :en)
    assert_not_equal "Not allowed", @account.firm.reload.name
  end

  private

  def valid_params(account: {}, profile: {}, firm: {})
    {
      account: { first_name: @account.user.first_name, last_name: @account.user.last_name, email_address: @account.user.email_address, locale: @account.user.locale }.merge(account),
      profile: { bar_association: @account.profile.bar_association, bar_number: @account.profile.bar_number, professional_email: @account.profile.professional_email, bar_admission_year: @account.profile.bar_admission_year, spoken_languages: @account.profile.spoken_languages, practice_areas: @account.profile.practice_areas, court_preferences: @account.profile.court_preferences, availability_note: @account.profile.availability_note }.merge(profile),
      firm: { name: @account.firm.name, enterprise_number: @account.firm.enterprise_number, vat_number: @account.firm.vat_number, billing_email: @account.firm.billing_email, phone: @account.firm.phone, address_line_1: @account.firm.address_line_1, postal_code: @account.firm.postal_code, city: @account.firm.city }.merge(firm)
    }
  end
end
