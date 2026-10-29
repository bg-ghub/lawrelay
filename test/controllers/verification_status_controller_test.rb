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

  test "a failed email resend stays on the retryable status page without exposing the error" do
    user = users(:one)
    user.update!(email_verified_at: nil)
    sign_in_as(user)
    original = EmailVerificationMailer.method(:verify)
    EmailVerificationMailer.define_singleton_method(:verify) { |*| raise ActiveJob::EnqueueError, "private SMTP user and token" }
    post verification_status_path(locale: :nl)
    assert_redirected_to verification_status_path(locale: :nl)
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :nl), flash[:alert]
    assert_nil flash[:notice]
    assert_not_includes response.body, "private SMTP"
    EmailVerificationMailer.define_singleton_method(:verify, original)

    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post verification_status_path(locale: :nl)
    end
    assert_equal I18n.t("auth.verification_status.resent", locale: :nl), flash[:notice]
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  test "a rejected directory retry is reported without a false success notice" do
    sign_in_as(users(:one))
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| false }
    post retry_directory_verification_status_path(locale: :en)
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :en), flash[:alert]
    assert_nil flash[:notice]
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end
end
