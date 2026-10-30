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
    assert_equal "BE#{@account.firm.enterprise_number}", @account.firm.vat_number
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

  test "settings requires an enterprise number when an owner saves company details" do
    original_number = @account.firm.enterprise_number

    patch settings_path(locale: :en), params: valid_params(firm: { enterprise_number: "" })

    assert_response :unprocessable_content
    assert_includes response.body, "Enterprise number"
    assert_equal original_number, @account.firm.reload.enterprise_number
  end

  test "settings ignores a forged VAT number and keeps the derived value" do
    patch settings_path(locale: :en), params: valid_params(firm: { vat_number: "BE0000000000" })

    assert_redirected_to settings_path(locale: :en)
    assert_equal "BE#{@account.firm.enterprise_number}", @account.firm.reload.vat_number
  end

  test "formatting an unchanged enterprise number does not reset company verification" do
    @account.firm.update!(enterprise_number: "1234567894", verification_status: "verified", verified_at: Time.current)

    patch settings_path(locale: :en), params: valid_params(firm: { enterprise_number: "BE 1234.567.894" })

    assert_redirected_to settings_path(locale: :en)
    assert_equal "verified", @account.firm.reload.verification_status
  end

  test "billing recipient changes preserve professional verification and account isolation" do
    other = create_marketplace_account(prefix: "samebilling")
    @account.firm.update!(enterprise_number: "1234567894")
    other.firm.update!(enterprise_number: "1234567894")

    patch settings_path(locale: :en), params: valid_params(firm: { name: "My invoice recipient", enterprise_number: "2345678942" })

    assert_redirected_to settings_path(locale: :en)
    assert_equal I18n.t("settings.notices.updated", locale: :en), flash[:notice]
    assert_equal "My invoice recipient", @account.firm.reload.name
    assert_predicate @account.user.reload, :marketplace_verified?
    assert_equal [ @account.firm.id ], @account.user.firm_ids
    assert_equal "1234567894", other.firm.reload.enterprise_number
    assert_not_equal "My invoice recipient", other.firm.name
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

  test "a suspended firm remains suspended when its details are changed" do
    @account.firm.update!(verification_status: "suspended")

    patch settings_path(locale: :en), params: valid_params(firm: { name: "Changed invoice recipient", enterprise_number: "2345678942" })

    assert_equal "suspended", @account.firm.reload.verification_status
  end

  test "a rejected firm remains rejected when its details are changed" do
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
      firm: { name: @account.firm.name, enterprise_number: @account.firm.enterprise_number, vat_number: @account.firm.vat_number, billing_email: @account.firm.billing_email, phone: @account.firm.phone, address_line_1: @account.firm.address_line_1, postal_code: @account.firm.postal_code, city: @account.firm.city }.merge(firm)
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
