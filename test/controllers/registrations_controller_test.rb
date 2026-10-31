require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "creates a pending lawyer and minimal internal workspace atomically" do
    assert_enqueued_jobs 2 do
      assert_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ], 1 do
        post registration_path(locale: :en), params: { registration: valid_registration }
      end
    end

    user = User.order(:id).last
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "Ada", user.first_name
    assert_equal "owner", user.primary_membership.role
    assert_equal "pending", user.primary_firm.verification_status
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, user.primary_firm.name
    assert_nil user.primary_firm.enterprise_number
    assert_nil user.primary_firm.vat_number
    assert_nil user.primary_firm.billing_email
    assert_nil user.primary_firm.phone
    assert_nil user.primary_firm.address_line_1
    assert_nil user.primary_firm.postal_code
    assert_nil user.primary_firm.city
    assert_empty user.primary_firm.kbo_details
    assert_equal "pending", user.lawyer_profile.verification_status
    assert_equal "OVB", user.lawyer_profile.bar_association
    assert_match(/\APENDING-[0-9a-f-]{36}\z/i, user.lawyer_profile.bar_number)
    assert_equal valid_registration[:directory_profile_url], user.lawyer_profile.directory_profile_url
    assert_not_nil user.accepted_terms_at
    assert_equal RegistrationsController::TERMS_VERSION, user.accepted_terms_version
    assert_equal RegistrationsController::PRIVACY_VERSION, user.accepted_privacy_version
    assert cookies[:session_id]
  end

  test "does not create partial records without legal acceptance" do
    attributes = valid_registration.merge(terms_accepted: "0")

    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: attributes }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "must accept"
  end

  test "registration collects personal identity without company or billing fields in every locale" do
    %i[nl fr de en].each do |locale|
      get new_registration_path(locale:)

      assert_response :success
      assert_select "input#registration_first_name"
      assert_select "input#registration_last_name"
      assert_select "input[name='registration[email_address]']", count: 0
      assert_select "input#registration_directory_profile_url"
      assert_select "[data-controller*='business-lookup'], [data-controller*='company-number']", count: 0
      %w[firm_name enterprise_number vat_number billing_email phone address_line_1 postal_code city kbo_lookup_token].each do |field|
        assert_select "[name='registration[#{field}]'], #registration_#{field}", count: 0
      end
    end
  end

  test "email enqueue failure preserves the account and independently queues the directory check" do
    with_failed_verification_email do
      assert_enqueued_jobs 1, only: Directory::VerificationJob do
        assert_difference([ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ], 1) do
          post registration_path(locale: :en), params: { registration: valid_registration }
        end
      end
    end

    user = User.order(:id).last
    assert_redirected_to verification_status_path(locale: :en)
    assert cookies[:session_id]
    assert_not user.email_verified?
    follow_redirect!
    assert_response :success
    assert_includes response.body, I18n.t("auth.registration.delivery_delayed", locale: :en)
    assert_not_includes response.body, "private adapter details"
    assert_no_difference "User.count" do
      assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
        post verification_status_path(locale: :en)
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
  end

  test "directory enqueue failure keeps the already queued mail and can be retried" do
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| raise SolidQueue::Job::EnqueueError, "private adapter details" }
    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post registration_path(locale: :en), params: { registration: valid_registration }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal I18n.t("auth.registration.delivery_delayed", locale: :en), flash[:alert]
    Directory::VerificationJob.define_singleton_method(:perform_later, original)

    assert_no_difference "User.count" do
      assert_enqueued_jobs 1, only: Directory::VerificationJob do
        post retry_directory_verification_status_path(locale: :en)
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "a rejected enqueue result does not announce a successfully started confirmation" do
    with_failed_verification_email(result: false) do
      post registration_path(locale: :fr), params: { registration: valid_registration }
    end
    assert_redirected_to verification_status_path(locale: :fr)
    assert_equal I18n.t("auth.registration.delivery_delayed", locale: :fr), flash[:alert]
    assert_nil flash[:notice]
  end

  test "rejects a short password submitted without browser validation" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(password: "short", password_confirmation: "short") }
    end
    assert_response :unprocessable_content
  end

  test "requires an official Advocaat.be lawyer profile link" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(directory_profile_url: "https://example.test/lawyer") }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "Advocaat.be"
  end

  test "uses the directory's strict canonical URL rules" do
    invalid_urls = [
      "https://www.advocaat.be:444/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      "https://user@www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      "https://www.advocaat.be/fr/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    ]

    invalid_urls.each do |url|
      assert_no_difference "User.count" do
        post registration_path(locale: :en), params: { registration: valid_registration.merge(directory_profile_url: url) }
      end
    end
  end

  test "does not reserve a public directory UUID while registration is pending" do
    first = valid_registration
    second = valid_registration(
      first_name: "Grace", last_name: "Hopper", email_address: "grace@law.example"
    )

    assert_difference "LawyerProfile.count", 2 do
      post registration_path(locale: :en), params: { registration: first }
      post registration_path(locale: :en), params: { registration: second }
    end

    profiles = LawyerProfile.order(:id).last(2)
    assert_equal [ first[:directory_profile_url] ], profiles.pluck(:directory_profile_url).uniq
    assert_not_equal profiles.first.bar_number, profiles.second.bar_number
    assert profiles.all? { |profile| profile.bar_number.start_with?("PENDING-") }
  end

  test "accounts receive separate workspaces without a supplied company identity" do
    first = valid_registration
    second = valid_registration(first_name: "Grace", last_name: "Hopper", email_address: "grace@law.example")

    assert_difference [ "User.count", "Firm.count", "Membership.count" ], 2 do
      post registration_path(locale: :en), params: { registration: first }
      post registration_path(locale: :en), params: { registration: second }
    end

    first_user = User.find_by!(email_address: first[:email_address])
    second_user = User.find_by!(email_address: second[:email_address])
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, first_user.primary_firm.name
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, second_user.primary_firm.name
    assert_not_equal first_user.primary_firm.id, second_user.primary_firm.id
    assert_equal [ first_user.id ], first_user.primary_firm.user_ids
    assert_equal [ second_user.id ], second_user.primary_firm.user_ids
  end

  test "ignores forged legacy company and billing attributes including a lookup token" do
    original = BusinessRegistry::Preview.method(:apply)
    BusinessRegistry::Preview.define_singleton_method(:apply) { |*| raise "Registration must not apply company details" }
    assert_difference "Firm.count", 1 do
      post registration_path(locale: :en), params: {
        registration: valid_registration.merge(
          firm_name: "Forged Legal", enterprise_number: "invalid", vat_number: "BE0000000000",
          billing_email: "billing@example.test", phone: "+3225550199", address_line_1: "Private street 10",
          postal_code: "1000", city: "Brussels", kbo_lookup_token: "forged-token"
        )
      }
    end

    assert_redirected_to verification_status_path(locale: :en)
    firm = User.order(:id).last.primary_firm
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, firm.name
    %w[enterprise_number vat_number billing_email phone address_line_1 postal_code city].each do |attribute|
      assert_nil firm.public_send(attribute), attribute
    end
    assert_empty firm.kbo_details
  ensure
    BusinessRegistry::Preview.define_singleton_method(:apply, original) if original
  end

  test "the listed email is authoritative even when another email is posted" do
    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(email_address: "forged@example.test") }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "ada@law.example", User.order(:id).last.email_address
    assert_nil User.find_by(email_address: "forged@example.test")
    assert_not User.order(:id).last.email_verified?
  end

  test "signup cannot use an arbitrary email without a signed directory result" do
    assert_no_difference [ "User.count", "Firm.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.except(:directory_preview_token) }
    end
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t("signup_profile.errors.invalid_preview", locale: :en)
    assert_select "input[name='registration[email_address]']", count: 0
  end

  private

  def with_failed_verification_email(result: nil)
    original = EmailVerificationMailer.method(:verify)
    delivery = Object.new
    delivery.define_singleton_method(:deliver_later) do
      raise ActiveJob::EnqueueError, "private adapter details" unless result == false

      false
    end
    EmailVerificationMailer.define_singleton_method(:verify) { |*| delivery }
    yield
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  def valid_registration(first_name: "Ada", last_name: "Lovelace", email_address: "ada@law.example")
    url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"
    result = Directory::SignupProfile::Result.new(status: :ok, profile_url: url, name: "#{first_name} #{last_name}",
      first_name:, last_name:, email_address:, profile_attributes: {})
    {
      first_name:,
      last_name:,
      email_address:,
      password: "correct-horse-battery-staple",
      password_confirmation: "correct-horse-battery-staple",
      directory_profile_url: url,
      directory_preview_token: Directory::SignupPreview.issue(result),
      locale: "en",
      terms_accepted: "1"
    }
  end
end
