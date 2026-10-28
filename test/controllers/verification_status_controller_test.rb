require "test_helper"

class VerificationStatusControllerTest < ActionDispatch::IntegrationTest
  test "requires authentication" do
    get verification_status_path(locale: :en)

    assert_redirected_to new_session_path(locale: :en)
  end

  test "shows the current verification states" do
    user = users(:one)
    firm = Firm.create!(name: "Example Legal", verification_status: "pending")
    user.memberships.create!(firm: firm, role: "owner")
    user.create_lawyer_profile!(bar_association: "BRUSSELS", bar_number: "ONE-1", verification_status: "pending")
    sign_in_as(user)

    get verification_status_path(locale: :en)

    assert_response :success
    assert_includes response.body, "Professional review"
  end
end
