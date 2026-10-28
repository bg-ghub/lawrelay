require "test_helper"

class BillingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email_address: "owner-#{SecureRandom.uuid}@example.test", password: "password123", password_confirmation: "password123", first_name: "Billing", last_name: "Owner")
    @firm = Firm.create!(name: "Billing Firm #{SecureRandom.uuid}", verification_status: "verified", verified_at: Time.current)
    Membership.create!(user: @owner, firm: @firm, role: "owner")
    verify_user @owner
    sign_in_as @owner
  end

  test "firm owner can view billing and request one manual invoice" do
    get billing_url(locale: "en")

    assert_response :success
    assert_select "h1", /LawRelay plan/

    post billing_checkout_url(locale: "en")

    assert_redirected_to billing_url(locale: "en")
    assert_equal 1, Invoice.count
    assert_equal "manual_required", Invoice.last.peppol_status
  end

  test "firm member cannot request an invoice" do
    member = User.create!(email_address: "member-#{SecureRandom.uuid}@example.test", password: "password123", password_confirmation: "password123", first_name: "Billing", last_name: "Member")
    Membership.create!(user: member, firm: @firm, role: "member")
    verify_user member
    sign_out
    sign_in_as member

    post billing_checkout_url(locale: "en")

    assert_redirected_to billing_url(locale: "en")
    assert_empty Invoice.all
  end

  private

  def verify_user(user)
    user.update!(email_verified_at: Time.current)
    LawyerProfile.create!(user:, bar_association: "OVB", bar_number: "#{SecureRandom.random_number(1_000_000)}", verification_status: "verified", verified_at: Time.current)
  end
end
