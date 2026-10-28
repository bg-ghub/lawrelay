require "test_helper"

class DirectoryAccountSuspensionTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    @user = users(:one)
    @profile = @user.create_lawyer_profile!(
      bar_association: "OVB", bar_number: "SUSPENDED-QUEUE",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_name: @user.full_name, directory_email: "official@example.test",
      directory_identity_digest: "synthetic-evidence", directory_checked_at: Time.current
    )
    @user.update!(suspended_at: Time.current, suspension_reason: "Account review")
  end

  test "a queued verification skips suspended accounts before requesting a lookup" do
    original = Directory::Verification.method(:request!)
    Directory::Verification.define_singleton_method(:request!) { |**| raise "Suspended account reached lookup service" }

    Directory::VerificationJob.perform_now(@user.id)

    assert_equal "pending", @profile.reload.verification_status
  ensure
    Directory::Verification.define_singleton_method(:request!, original) if original
  end

  test "a queued directory confirmation sends no email for a suspended account" do
    assert_no_emails do
      Directory::ConfirmationJob.perform_now(@profile.id)
    end

    assert_nil @profile.reload.directory_confirmation_requested_at
  end
end
