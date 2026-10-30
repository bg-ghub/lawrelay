require "test_helper"
require_relative "../support/marketplace_test_factory"

class KboBillingPreviewTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  KBO_ATTRIBUTES = {
    name: "Fictional KBO Legal BV",
    enterprise_number: "1234567894",
    address_line_1: "Registry Street 10",
    postal_code: "1000",
    city: "Brussels"
  }.freeze

  test "registration persists signed KBO billing provenance without changing the lawyer identity" do
    attributes = registration_attributes.merge(KBO_ATTRIBUTES).merge(kbo_lookup_token: preview_token)

    assert_difference [ "User.count", "Firm.count", "Membership.count" ], 1 do
      post registration_path(locale: :en), params: { registration: attributes }
    end

    user = User.find_by!(email_address: attributes[:email_address])
    assert_equal "Ada", user.first_name
    assert_equal "Lovelace", user.last_name
    assert_equal KBO_ATTRIBUTES.slice(:name, :address_line_1, :postal_code, :city), user.primary_firm.attributes.symbolize_keys.slice(:name, :address_line_1, :postal_code, :city)
    assert_equal expected_details, user.primary_firm.kbo_details
  end

  test "settings save keeps manual billing email, ignores raw metadata, and preserves verification" do
    account = create_marketplace_account(prefix: "kbo-settings")
    sign_in_as(account.user)

    patch settings_path(locale: :en), params: settings_params(account, KBO_ATTRIBUTES.merge(
      billing_email: "manual-invoices@example.test",
      kbo_lookup_token: preview_token,
      kbo_details: { "snapshot_date" => "2000-01-01", "fields" => [ "city" ] }
    ))

    assert_redirected_to settings_path(locale: :en)
    firm = account.firm.reload
    assert_equal "manual-invoices@example.test", firm.billing_email
    assert_equal expected_details, firm.kbo_details
    assert_predicate account.user.reload, :marketplace_verified?
  end

  test "manual settings changes retain only unchanged KBO fields and a new number clears attribution" do
    account = create_marketplace_account(prefix: "kbo-edits")
    sign_in_as(account.user)
    save_kbo_details(account)

    patch settings_path(locale: :en), params: settings_params(account, KBO_ATTRIBUTES.merge(name: "Manual invoice recipient"))
    assert_redirected_to settings_path(locale: :en)
    assert_equal %w[address_line_1 city enterprise_number postal_code], account.firm.reload.kbo_details.fetch("fields").sort

    patch settings_path(locale: :en), params: settings_params(account, KBO_ATTRIBUTES.merge(name: "Manual invoice recipient", enterprise_number: "2345678942"))
    assert_redirected_to settings_path(locale: :en)
    assert_equal({}, account.firm.reload.kbo_details)
  end

  test "assignment creation snapshots signed KBO details independently of the current firm" do
    account = create_marketplace_account(prefix: "kbo-assignment")
    outsider = create_marketplace_account(prefix: "kbo-outsider")
    sign_in_as(account.user)

    assert_difference "Assignment.count", 1 do
      post assignments_path(locale: :en), params: {
        assignment: assignment_attributes.merge(KBO_ATTRIBUTES.transform_keys { |key| "invoice_#{key}".to_sym }).merge(
          kbo_lookup_token: preview_token,
          firm_id: outsider.firm.id,
          creator_user_id: outsider.user.id
        )
      }
    end

    assignment = Assignment.order(:id).last
    assert_equal account.firm, assignment.firm
    assert_equal account.user, assignment.creator_user
    assert_equal expected_details, assignment.invoice_kbo_details

    account.firm.update!(name: "Changed company", enterprise_number: "2345678942", address_line_1: "Changed Street 1")
    assert_equal expected_details, assignment.reload.invoice_kbo_details
  end

  private

  def preview_token
    BusinessRegistry::Preview.issue(
      BusinessRegistry::PublicLookup::Result.new(status: :ok, attributes: KBO_ATTRIBUTES, snapshot_date: Date.new(2026, 10, 29))
    )
  end

  def expected_details
    { "snapshot_date" => "2026-10-29", "fields" => BusinessRegistry::Preview::FIELDS }
  end

  def registration_attributes
    {
      first_name: "Ada", last_name: "Lovelace", email_address: "kbo-registration-#{SecureRandom.hex(6)}@example.test",
      password: "correct-horse-battery-staple", password_confirmation: "correct-horse-battery-staple",
      firm_name: KBO_ATTRIBUTES[:name], enterprise_number: KBO_ATTRIBUTES[:enterprise_number],
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      locale: "en", terms_accepted: "1"
    }
  end

  def settings_params(account, firm)
    {
      account: { first_name: account.user.first_name, last_name: account.user.last_name, locale: account.user.locale },
      profile: { spoken_languages: account.profile.spoken_languages, practice_areas: account.profile.practice_areas, court_preferences: account.profile.court_preferences },
      firm: {
        name: account.firm.name, enterprise_number: account.firm.enterprise_number, billing_email: account.firm.billing_email,
        phone: account.firm.phone, address_line_1: account.firm.address_line_1, postal_code: account.firm.postal_code, city: account.firm.city
      }.merge(firm)
    }
  end

  def save_kbo_details(account)
    patch settings_path(locale: :en), params: settings_params(account, KBO_ATTRIBUTES.merge(kbo_lookup_token: preview_token))
    assert_redirected_to settings_path(locale: :en)
  end

  def assignment_attributes
    {
      kind: "court_replacement", title: "KBO snapshot hearing", description: "A bounded assignment without case details.",
      court: "Enterprise Court", city: "Brussels", starts_at: 3.days.from_now, response_deadline_at: 2.days.from_now,
      duration_minutes: 60, practice_area: "Commercial law", content_rules_accepted: "1",
      invoice_email: "billing@example.test"
    }
  end
end
