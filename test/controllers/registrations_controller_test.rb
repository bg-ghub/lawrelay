require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "creates a pending lawyer and firm atomically" do
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
    second = valid_registration.merge(
      first_name: "Grace", last_name: "Hopper", email_address: "grace@law.example", firm_name: "Hopper Legal",
      enterprise_number: "9876543210", vat_number: "BE9876543210"
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

  def valid_registration
    {
      first_name: "Ada",
      last_name: "Lovelace",
      email_address: "ada@law.example",
      password: "correct-horse-battery-staple",
      password_confirmation: "correct-horse-battery-staple",
      firm_name: "Lovelace Legal",
      enterprise_number: "0123456789",
      vat_number: "BE0123456789",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      locale: "en",
      terms_accepted: "1"
    }
  end
end
