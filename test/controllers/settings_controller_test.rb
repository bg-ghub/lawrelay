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
    assert_select "h1", text: I18n.t("settings.heading", locale: :en)
    assert_select "[name^='firm['], [data-controller*='business-lookup'], [data-controller*='company-number']", count: 0
  end

  test "updates language while preserving imported identity profile and company details" do
    original_firm = @account.firm.attributes
    original_profile = @account.profile.attributes
    original_identity = @account.user.attributes.slice("first_name", "last_name", "email_address", "email_verified_at")
    assert_difference "AuditEvent.count", 1 do
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
    assert_equal original_identity, @account.user.attributes.slice(*original_identity.keys)
    assert_equal "fr", @account.user.locale
    assert_equal original_profile, @account.profile.attributes
    assert_equal original_firm, @account.firm.attributes
    assert_equal I18n.t("settings.notices.updated", locale: :fr), flash[:notice]
  end

  test "settings ignores a forged direct email update" do
    original_email = @account.user.email_address

    assert_no_enqueued_emails do
      patch settings_path(locale: :en), params: valid_params(account: { email_address: "new-address@example.test" })
    end

    assert_redirected_to settings_path(locale: :en)
    assert_equal original_email, @account.user.reload.email_address
  end

  test "personal profile fields remain unchanged when posted directly" do
    @account.firm.update!(name: Firm::INTERNAL_WORKSPACE_NAME, enterprise_number: nil,
      billing_email: nil, phone: nil, address_line_1: nil, postal_code: nil, city: nil)
    original_firm = @account.firm.reload.attributes

    original_profile = @account.profile.attributes
    patch settings_path(locale: :en), params: valid_params(profile: { availability_note: "Forged availability" })

    assert_redirected_to settings_path(locale: :en)
    assert_equal original_profile, @account.profile.reload.attributes
    assert_equal original_firm, @account.firm.reload.attributes
  end

  test "settings ignores all forged company and billing attributes without applying a lookup" do
    original_firm = @account.firm.attributes
    original = BusinessRegistry::Preview.method(:apply)
    BusinessRegistry::Preview.define_singleton_method(:apply) { |*| raise "Settings must not apply company details" }

    assert_no_difference "AuditEvent.where(auditable: @account.firm).count" do
      patch settings_path(locale: :en), params: valid_params(firm: {
        name: "Forged legal recipient", enterprise_number: "invalid", vat_number: "BE0000000000",
        billing_email: "billing@example.test", phone: "+3225550199", address_line_1: "Private street 10",
        postal_code: "1000", city: "Brussels", kbo_lookup_token: "forged-token",
        verification_status: "verified", verified_at: Time.current
      })
    end

    assert_redirected_to settings_path(locale: :en)
    assert_equal original_firm, @account.firm.reload.attributes
    assert_predicate @account.user.reload, :marketplace_verified?
  ensure
    BusinessRegistry::Preview.define_singleton_method(:apply, original) if original
  end

  test "forged company details cannot join workspaces or alter another account" do
    other = create_marketplace_account(prefix: "separateworkspace")
    original_firm = @account.firm.attributes
    original_other_firm = other.firm.attributes

    patch settings_path(locale: :en), params: valid_params(firm: { id: other.firm.id, name: other.firm.name, enterprise_number: other.firm.enterprise_number })

    assert_redirected_to settings_path(locale: :en)
    assert_equal [ @account.firm.id ], @account.user.reload.firm_ids
    assert_equal original_firm, @account.firm.reload.attributes
    assert_equal original_other_firm, other.firm.reload.attributes
  end

  test "forged names leave the imported identity directory evidence and sessions unchanged" do
    profile = verified_directory_profile!
    original_user = @account.user.attributes
    original_profile = profile.attributes
    session_ids = @account.user.sessions.pluck(:id)

    assert_no_enqueued_jobs do
      assert_no_difference "AuditEvent.count" do
        patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed", last_name: "", email_address: "forged@example.test" })
      end
    end

    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, profile.reload.attributes
    assert_equal session_ids, @account.user.sessions.pluck(:id)
  end

  test "a suspended profile remains suspended when identity details are changed" do
    profile = verified_directory_profile!(verification_status: "suspended")
    original_profile = profile.attributes

    assert_no_enqueued_jobs only: Directory::VerificationJob do
      patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed" })
    end

    assert_equal original_profile, profile.reload.attributes
  end

  test "ignored identity input cannot trigger an unavailable directory queue" do
    profile = verified_directory_profile!
    original_name = @account.user.first_name
    original_profile = profile.attributes
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| raise SolidQueue::Job::EnqueueError, "private adapter details" }
    patch settings_path(locale: :en), params: valid_params(account: { first_name: "Corrected" })
    assert_redirected_to settings_path(locale: :en)
    assert_equal original_name, @account.user.reload.first_name
    assert_equal original_profile, @account.profile.reload.attributes
    assert_equal I18n.t("settings.notices.updated", locale: :en), flash[:notice]
    assert_nil flash[:alert]
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "a rejected profile remains rejected when identity details are changed" do
    profile = verified_directory_profile!(verification_status: "rejected")
    original_profile = profile.attributes

    assert_no_enqueued_jobs only: Directory::VerificationJob do
      patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed" })
    end

    assert_equal original_profile, profile.reload.attributes
  end

  test "a suspended workspace remains suspended when company details are forged" do
    @account.firm.update!(verification_status: "suspended")

    patch settings_path(locale: :en), params: valid_params(firm: { name: "Changed invoice recipient", enterprise_number: "2345678942" })

    assert_equal "suspended", @account.firm.reload.verification_status
  end

  test "a rejected workspace remains rejected when company details are forged" do
    @account.firm.update!(verification_status: "rejected")

    patch settings_path(locale: :en), params: valid_params(firm: { name: "Changed invoice recipient", enterprise_number: "2345678942" })

    assert_equal "rejected", @account.firm.reload.verification_status
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
      profile: { bar_admission_year: @account.profile.bar_admission_year, spoken_languages: @account.profile.spoken_languages, practice_areas: @account.profile.practice_areas, court_preferences: @account.profile.court_preferences, availability_note: @account.profile.availability_note }.merge(profile),
      firm: firm
    }
  end

  def verified_directory_profile!(verification_status: "verified")
    @account.profile.update!(
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @account.user.full_name,
      directory_email: @account.user.email_address,
      directory_checked_at: Time.current,
      directory_email_verified_at: Time.current,
      directory_professional_address: "Zavelstraat 13, 1000 Brussel", directory_bar_name: "Balie Brussel",
      directory_confirmation_requested_at: Time.current,
      directory_identity_digest: "directory-proof",
      verification_status:,
      verified_at: (Time.current if verification_status == "verified")
    )
    @account.profile
  end
end
