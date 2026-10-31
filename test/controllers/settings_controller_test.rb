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

  test "updates account and personal profile with an audit trail while ignoring company details" do
    original_firm = @account.firm.attributes
    assert_difference "AuditEvent.count", 2 do
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
    assert_equal original_firm, @account.firm.attributes
    assert_equal I18n.t("settings.notices.review_required", locale: :fr), flash[:notice]
  end

  test "settings ignores a forged direct email update" do
    original_email = @account.user.email_address

    assert_no_enqueued_emails do
      patch settings_path(locale: :en), params: valid_params(account: { email_address: "new-address@example.test" })
    end

    assert_redirected_to settings_path(locale: :en)
    assert_equal original_email, @account.user.reload.email_address
  end

  test "personal settings can be saved for a minimal workspace without company details" do
    @account.firm.update!(name: Firm::INTERNAL_WORKSPACE_NAME, enterprise_number: nil,
      billing_email: nil, phone: nil, address_line_1: nil, postal_code: nil, city: nil)
    original_firm = @account.firm.reload.attributes

    patch settings_path(locale: :en), params: valid_params(profile: { availability_note: "Available Wednesday" })

    assert_redirected_to settings_path(locale: :en)
    assert_equal "Available Wednesday", @account.profile.reload.availability_note
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

  test "name changes reset directory verification and queue a fresh check" do
    profile = verified_directory_profile!

    assert_enqueued_with(job: Directory::VerificationJob, args: [ @account.user.id ]) do
      patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed" })
    end

    profile.reload
    assert_equal "pending", profile.verification_status
    assert_nil profile.verified_at
    assert_nil profile.directory_profile_id
    assert_nil profile.directory_email
    assert_nil profile.directory_identity_digest
  end

  test "a suspended profile remains suspended when identity details are changed" do
    profile = verified_directory_profile!(verification_status: "suspended")

    assert_no_enqueued_jobs only: Directory::VerificationJob do
      patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed" })
    end

    profile.reload
    assert_equal "suspended", profile.verification_status
    assert_nil profile.directory_profile_id
    assert_nil profile.directory_identity_digest
  end

  test "a saved name correction remains recoverable when its directory check cannot be queued" do
    verified_directory_profile!
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| raise SolidQueue::Job::EnqueueError, "private adapter details" }
    patch settings_path(locale: :en), params: valid_params(account: { first_name: "Corrected" })
    assert_redirected_to settings_path(locale: :en)
    assert_equal "Corrected", @account.user.reload.first_name
    assert_equal "pending", @account.profile.reload.verification_status
    assert flash[:notice].present?
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :en), flash[:alert]
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "a rejected profile remains rejected when identity details are changed" do
    profile = verified_directory_profile!(verification_status: "rejected")

    assert_no_enqueued_jobs only: Directory::VerificationJob do
      patch settings_path(locale: :en), params: valid_params(account: { first_name: "Changed" })
    end

    profile.reload
    assert_equal "rejected", profile.verification_status
    assert_nil profile.directory_profile_id
    assert_nil profile.directory_identity_digest
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
      directory_confirmation_requested_at: Time.current,
      directory_identity_digest: "directory-proof",
      verification_status:,
      verified_at: (Time.current if verification_status == "verified")
    )
    @account.profile
  end
end
