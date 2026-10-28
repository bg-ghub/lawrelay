require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "creates a pending lawyer and firm atomically" do
    assert_enqueued_emails 1 do
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
    assert_not_nil user.accepted_terms_at
    assert_equal RegistrationsController::TERMS_VERSION, user.accepted_terms_version
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

  private

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
      bar_association: "BRUSSELS",
      bar_number: "ADA-1843",
      locale: "en",
      terms_accepted: "1"
    }
  end
end
