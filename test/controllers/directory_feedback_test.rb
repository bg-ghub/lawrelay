require "test_helper"

class DirectoryFeedbackTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @user.update!(email_verified_at: Time.current)
    firm = Firm.create!(name: "Feedback Legal", verification_status: "pending")
    @user.memberships.create!(firm:, role: "owner")
    @profile = @user.create_lawyer_profile!(bar_association: "OVB", bar_number: "VIEW-FEEDBACK-#{SecureRandom.hex(5)}",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    sign_in_as(@user)
  end

  test "lookup failures render localized safe guidance and existing recovery links" do
    LawyerProfile::DIRECTORY_LOOKUP_FAILURES.each do |code|
      AuditEvent.create!(auditable: @profile, action: "verification.directory_lookup_failed",
        metadata: { status: code, identity_digest: @profile.directory_lookup_identity_digest })

      %w[nl fr de en].each do |locale|
        get verification_status_path(locale:)
        assert_response :success
        assert_select "h2", text: I18n.t("directory_feedback.attention_title", locale:)
        assert_select "p", text: I18n.t("directory_feedback.failures.#{code}", locale:)
        assert_select "form[action='#{retry_directory_verification_status_path(locale:)}']", count: 1
        assert_select "a[href='mailto:info@lawrelay.be']"
        assert_select "section.form-section a[href='#{settings_path(locale:)}']", text: I18n.t("directory_feedback.check_name", locale:), count: 1 if code == "name_mismatch"
        assert_not_includes response.body, "Translation missing"
      end
    end
  end

  test "official-email confirmation offers the existing retry route in each locale" do
    @profile.update!(directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @user.full_name, directory_email: "professional@example.test", directory_checked_at: Time.current)

    %w[nl fr de en].each do |locale|
      get verification_status_path(locale:)
      assert_response :success
      assert_select "button", text: I18n.t("directory_feedback.resend_confirmation", locale:)
      assert_select "form[action='#{retry_directory_verification_status_path(locale:)}']", count: 1
    end
  end
end
