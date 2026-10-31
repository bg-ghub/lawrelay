require "test_helper"
require_relative "../support/marketplace_test_factory"

class ManualActivationEmailDeliveryTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @account = create_marketplace_account(prefix: "manual-delivery", verified: false, email_verified: false)
    @user, @profile = @account.user, @account.profile
    profile_id = SecureRandom.uuid
    @profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: @user.full_name, directory_email: @user.email_address,
      directory_checked_at: Time.current, directory_identity_digest: "synthetic-identity")
    @previously_queued_job = EmailVerificationDeliveryJob.new("EmailVerificationMailer", "verify", "deliver_now", args: [ @user ]).serialize
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    secret = @admin.begin_admin_mfa_setup!
    @admin.enable_admin_mfa!(ROTP::TOTP.new(secret, issuer: "LawRelay").now)
    result = Admin::ManualActivation.call(user: @user, actor: @admin,
      note: "Operator approved this member without another email.", identity_digest: @profile.email_review_current_identity_digest)
    assert result.success?, result.status.to_s
    @user.reload
    sign_in_as(@user)
  end

  test "previously queued verification delivery skips a manually approved member" do
    assert_no_enqueued_jobs do
      assert_no_emails { ActiveJob::Base.execute(@previously_queued_job) }
    end
    assert_not @user.reload.email_verified?
    assert @user.marketplace_verified?
  end

  test "onboarding and admin resend requests do not queue another verification email" do
    assert_no_enqueued_jobs do
      assert Onboarding::Delivery.request(@user, directory: false)
      delivery = Admin::VerificationDelivery.new(actor: @admin, user: @user)
      assert_not delivery.eligible?
      assert_equal :ineligible, delivery.request
    end
    assert_not @user.reload.email_verified?
  end

  test "saving preferences keeps access and does not send a verification email" do
    assert_no_enqueued_jobs do
      patch settings_path(locale: :en), params: { profile: { availability_note: "Available on Wednesdays" } }
    end
    assert_redirected_to settings_path(locale: :en)
    assert_equal "Available on Wednesdays", @profile.reload.availability_note
    assert @user.reload.marketplace_verified?
    assert_not @user.email_verified?
  end

  test "the old verification resend endpoint also avoids mailing a manually approved member" do
    assert_no_enqueued_jobs { post verification_status_path(locale: :en) }
    assert_redirected_to verification_status_path(locale: :en)
    follow_redirect!
    assert_redirected_to dashboard_path(locale: :en)
  end

  test "identity changes restore the ordinary email confirmation requirement" do
    @user.update!(first_name: "Changed")
    assert @user.reload.email_verification_required?
    assert_not @user.marketplace_verified?
    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      assert Onboarding::Delivery.request(@user, directory: false)
    end
  end

  test "an existing genuine email link can still confirm the mailbox normally" do
    token = @user.email_verification_token
    get email_verification_path(token:, locale: :en)
    assert_response :success
    assert_not @user.reload.email_verified?
    assert_no_enqueued_jobs do
      post confirm_email_verification_path(token:, locale: :en)
    end
    assert_redirected_to dashboard_path(locale: :en)
    assert @user.reload.email_verified?
    assert @profile.reload.directory_email_verified?
    assert @user.marketplace_verified?
  end

  test "a member cannot grant manual approval through forged settings fields" do
    other = create_marketplace_account(prefix: "forged-manual", email_verified: false)
    profile_id = SecureRandom.uuid
    other.profile.update!(directory_profile_id: profile_id,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{profile_id}",
      directory_name: other.user.full_name, directory_email: other.user.email_address,
      directory_checked_at: Time.current)
    sign_in_as(other.user)

    assert_no_enqueued_jobs do
      patch settings_path(locale: :en), params: { profile: {
        manual_activation_approved_at: Time.current.iso8601,
        manual_activation_approved_by_user_id: @admin.id,
        manual_activation_identity_digest: other.profile.email_review_current_identity_digest
      } }
    end

    assert_redirected_to settings_path(locale: :en)
    assert_nil other.profile.reload.manual_activation_approved_at
    assert_nil other.profile.manual_activation_approved_by_user_id
    assert_nil other.profile.manual_activation_identity_digest
    assert_not other.user.reload.marketplace_verified?
  end
end
