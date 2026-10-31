require "test_helper"
require_relative "../support/marketplace_test_factory"

class EmailAccessReviewDeliveryJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "decision-mail")
    @profile = @account.profile
    @profile.assign_attributes(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_profile_id: SecureRandom.uuid, directory_name: @account.user.full_name,
      directory_email: "old-listed@example.test", directory_checked_at: Time.current,
      email_review_status: "approved", email_review_email_address: @account.user.email_address,
      email_review_requested_at: 1.minute.ago, email_reviewed_at: Time.current,
      email_review_note: "Checked independent public contact.")
    @profile.email_review_identity_digest = @profile.email_review_current_identity_digest
    @profile.save!
    @stamp = @profile.email_reviewed_at.utc.iso8601(6)
  end

  test "sends approval only to the confirmed working address" do
    assert_emails 1 do
      EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp)
    end
    message = ActionMailer::Base.deliveries.last
    assert_equal [ @account.user.email_address ], message.to
    assert_not_includes message.to, @profile.directory_email
    assert_not(/translation missing/i.match?(message.body.to_s))
  end

  test "resubmission and a changed source invalidate an old queued approval message" do
    @profile.update!(email_review_status: "pending", email_reviewed_at: nil)
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
    @profile.update!(email_review_status: "approved", email_reviewed_at: Time.iso8601(@stamp), directory_email: "different-listed@example.test")
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
  end

  test "unconfirmed changed or suspended users never receive a decision message" do
    @account.user.update!(email_verified_at: nil)
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
    @account.user.update!(email_address: "later-change@example.test", email_verified_at: Time.current)
    @account.user.update!(email_verified_at: Time.current)
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
    @account.user.update!(suspended_at: Time.current)
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
  end

  test "a rejected request sends a short decision to a confirmed account" do
    @profile.update!(email_review_status: "rejected", verification_status: "pending", verified_at: nil)
    assert_emails 1 do
      EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp)
    end
  end

  test "a changed directory source invalidates a queued rejection message" do
    @profile.update!(email_review_status: "rejected", verification_status: "pending", verified_at: nil)
    @profile.update!(directory_email: "changed-after-review@example.test")
    assert_no_emails { EmailAccessReviewDeliveryJob.perform_now(@profile.id, @stamp) }
  end
end
