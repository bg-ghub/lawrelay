require "test_helper"

class Admin::VerificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_user(email: "admin-verification@example.test", system_role: "admin")
    configure_admin_mfa(@admin)
    @review_user = create_user(email: "pending-lawyer@example.test")
    @review_firm = Firm.create!(name: "Pending Legal", enterprise_number: "PENDING001")
    @review_user.memberships.create!(firm: @review_firm, role: "owner")
    @review_profile = @review_user.create_lawyer_profile!(
      bar_association: "OVB",
      bar_number: "PENDING-BAR-001",
      professional_email: @review_user.email_address
    )
  end

  test "system admin can list pending verifications" do
    sign_in_as(@admin, admin_mfa: true)

    get "/en/admin/verifications"

    assert_response :success
    assert_select "h2", @review_user.full_name
    assert_select "body", text: /#{Regexp.escape(@review_user.email_address)}/
  end

  test "ordinary member cannot access verification console" do
    sign_in_as(@review_user)

    get "/en/admin/verifications"

    assert_redirected_to "/en"
  end

  test "system admin can approve firm and lawyer with an audit trail" do
    sign_in_as(@admin, admin_mfa: true)

    assert_difference("AuditEvent.count", 2) do
      patch "/en/admin/verifications/#{@review_user.id}", params: {
        decision: "approve",
        verification: { note: "Checked against the bar directory." }
      }
    end

    assert_redirected_to "/en/admin/verifications"
    assert_equal "verified", @review_firm.reload.verification_status
    assert_not_nil @review_firm.verified_at
    assert_equal "verified", @review_profile.reload.verification_status
    assert_equal "Checked against the bar directory.", @review_profile.verification_note
    assert_equal [ "verification.approved" ], AuditEvent.where(actor_user: @admin).distinct.pluck(:action)
  end

  test "system admin can reject a verification" do
    sign_in_as(@admin, admin_mfa: true)
    %w[nl fr de en].each do |locale|
      patch "/#{locale}/admin/verifications/#{@review_user.id}", params: {
        decision: "reject",
        verification: { note: "Bar number could not be confirmed." }
      }
      assert_redirected_to "/#{locale}/admin/verifications"
      assert_equal I18n.t("admin.verifications.notices.rejected", locale:, name: @review_user.full_name), flash[:notice]
    end
    assert_equal [ "verification.rejected" ], AuditEvent.where(actor_user: @admin).distinct.pluck(:action)
    assert_equal "rejected", @review_firm.reload.verification_status
    assert_nil @review_firm.verified_at
    assert_equal "rejected", @review_profile.reload.verification_status
    assert_nil @review_profile.verified_at
  end

  private

  def create_user(email:, system_role: "member")
    User.create!(
      email_address: email,
      password: "password1234",
      first_name: email.start_with?("admin") ? "Admin" : "Pending",
      last_name: "Lawyer",
      locale: "en",
      system_role: system_role,
      email_verified_at: Time.current
    )
  end

  def configure_admin_mfa(user)
    secret = user.begin_admin_mfa_setup!
    user.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
  end
end
