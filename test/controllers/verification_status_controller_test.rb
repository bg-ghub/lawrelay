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
    assert_select "h2", text: I18n.t("directory_onboarding.status.pending_title", locale: :en)
  end

  test "queues a directory retry without looking up the provider in the request" do
    user = users(:one)
    firm = Firm.create!(name: "Retry Legal", verification_status: "pending")
    user.memberships.create!(firm: firm, role: "owner")
    user.create_lawyer_profile!(bar_association: "OVB", bar_number: "RETRY-1", directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a")
    sign_in_as(user)

    assert_enqueued_with(job: Directory::VerificationJob, args: [ user.id ]) do
      post retry_directory_verification_status_path(locale: :en)
    end

    assert_redirected_to verification_status_path(locale: :en)
  end
end
