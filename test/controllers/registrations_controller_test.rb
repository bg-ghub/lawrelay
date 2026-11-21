require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "creates a pending lawyer and minimal internal workspace atomically" do
    assert_enqueued_jobs 2 do
      assert_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ], 1 do
        post registration_path(locale: :en), params: { registration: valid_registration }
      end
    end

    user = User.order(:id).last
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "Ada", user.first_name
    assert_equal "owner", user.primary_membership.role
    assert_equal "pending", user.primary_firm.verification_status
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, user.primary_firm.name
    assert_nil user.primary_firm.enterprise_number
    assert_nil user.primary_firm.vat_number
    assert_nil user.primary_firm.billing_email
    assert_nil user.primary_firm.phone
    assert_nil user.primary_firm.address_line_1
    assert_nil user.primary_firm.postal_code
    assert_nil user.primary_firm.city
    assert_empty user.primary_firm.kbo_details
    assert_equal "pending", user.lawyer_profile.verification_status
    assert_equal "OVB", user.lawyer_profile.bar_association
    assert_match(/\APENDING-[0-9a-f-]{36}\z/i, user.lawyer_profile.bar_number)
    assert_equal valid_registration[:directory_profile_url], user.lawyer_profile.directory_profile_url
    assert_not_nil user.accepted_terms_at
    assert_equal RegistrationsController::TERMS_VERSION, user.accepted_terms_version
    assert_equal RegistrationsController::PRIVACY_VERSION, user.accepted_privacy_version
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

  test "registration asks only for the profile link as professional information in every locale" do
    %i[nl fr de en].each do |locale|
      get new_registration_path(locale:)

      assert_response :success
      assert_select "input#registration_first_name, input#registration_last_name", count: 0
      assert_select "input[name='registration[email_address]']", count: 0
      assert_select "input#registration_directory_profile_url"
      assert_select "[data-controller*='business-lookup'], [data-controller*='company-number']", count: 0
      %w[firm_name enterprise_number vat_number billing_email phone address_line_1 postal_code city kbo_lookup_token].each do |field|
        assert_select "[name='registration[#{field}]'], #registration_#{field}", count: 0
      end
    end
  end

  test "email enqueue failure preserves the account and independently queues the directory check" do
    with_failed_verification_email do
      assert_enqueued_jobs 1, only: Directory::VerificationJob do
        assert_difference([ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ], 1) do
          post registration_path(locale: :en), params: { registration: valid_registration }
        end
      end
    end

    user = User.order(:id).last
    assert_redirected_to verification_status_path(locale: :en)
    assert cookies[:session_id]
    assert_not user.email_verified?
    follow_redirect!
    assert_response :success
    assert_includes response.body, I18n.t("auth.registration.delivery_delayed", locale: :en)
    assert_not_includes response.body, "private adapter details"
    assert_no_difference "User.count" do
      assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
        post verification_status_path(locale: :en)
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
  end

  test "directory enqueue failure keeps the already queued mail and can be retried" do
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| raise SolidQueue::Job::EnqueueError, "private adapter details" }
    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post registration_path(locale: :en), params: { registration: valid_registration }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal I18n.t("auth.registration.delivery_delayed", locale: :en), flash[:alert]
    Directory::VerificationJob.define_singleton_method(:perform_later, original)

    assert_no_difference "User.count" do
      assert_enqueued_jobs 1, only: Directory::VerificationJob do
        post retry_directory_verification_status_path(locale: :en)
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "a rejected enqueue result does not announce a successfully started confirmation" do
    with_failed_verification_email(result: false) do
      post registration_path(locale: :fr), params: { registration: valid_registration }
    end
    assert_redirected_to verification_status_path(locale: :fr)
    assert_equal I18n.t("auth.registration.delivery_delayed", locale: :fr), flash[:alert]
    assert_nil flash[:notice]
  end

  test "rejects a short password submitted without browser validation" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(password: "short", password_confirmation: "short") }
    end
    assert_response :unprocessable_content
  end

  test "requires an official Advocaat.be lawyer profile link" do
    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(directory_profile_url: "https://example.test/lawyer") }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "Advocaat.be"
  end

  test "uses the directory's strict canonical URL rules" do
    invalid_urls = [
      "https://www.advocaat.be:444/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "https://user@www.advocaat.be/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "https://www.advocaat.be/fr/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    ]

    invalid_urls.each do |url|
      assert_no_difference "User.count" do
        post registration_path(locale: :en), params: { registration: valid_registration.merge(directory_profile_url: url) }
      end
    end
  end

  test "legacy directory aliases create one canonical profile and retain signed identity" do
    canonical = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    legacy = canonical.sub("www.", "")
    attributes = valid_registration(profile_url: legacy)

    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: attributes }
    end

    assert_redirected_to verification_status_path(locale: :en)
    profile = User.order(:id).last.lawyer_profile
    assert_equal canonical, profile.directory_profile_url
    assert Directory::SignupPreview.read(token: attributes[:directory_preview_token], profile_url: legacy)
  end

  test "a canonical profile cannot be registered a second time through its legacy alias" do
    canonical = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    legacy = canonical.sub("www.", "")
    first = valid_registration(profile_url: canonical)
    second = valid_registration(profile_url: legacy).merge(
      request_alternative_email: "1", alternative_email_address: "second@law.example"
    )

    post registration_path(locale: :en), params: { registration: first }
    assert_redirected_to verification_status_path(locale: :en)

    assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count" ] do
      assert_no_enqueued_jobs do
        post registration_path(locale: :en), params: { registration: second }
      end
    end
    assert_response :unprocessable_content
    assert_select "a[href='#{new_session_path(locale: :en)}']"
    assert_select "a[href='#{new_password_path(locale: :en)}']"
    assert_select "a[href='mailto:support@lawrelay.be']"
  end

  test "old directory URL first then new UUID cannot create a second account" do
    old_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    new_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    first = valid_registration(profile_url: old_url, resolved_profile_url: new_url,
      email_address: "old-first@law.example")
    second = valid_registration(profile_url: new_url, resolved_profile_url: new_url,
      email_address: "new-second@law.example").merge(
        request_alternative_email: "1", alternative_email_address: "second-manual@law.example"
      )

    post registration_path(locale: :en), params: { registration: first }
    assert_redirected_to verification_status_path(locale: :en)
    counts = [ User.count, Session.count, Firm.count, Membership.count, LawyerProfile.count, Notification.count ]
    deliveries = ActionMailer::Base.deliveries.length
    assert_no_enqueued_jobs do
      post registration_path(locale: :en), params: { registration: second }
    end
    assert_response :unprocessable_content
    assert_equal counts, [ User.count, Session.count, Firm.count, Membership.count, LawyerProfile.count, Notification.count ]
    assert_equal deliveries, ActionMailer::Base.deliveries.length
  end

  test "new directory URL first then old UUID cannot create a second account" do
    old_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    new_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    first = valid_registration(profile_url: new_url, resolved_profile_url: new_url,
      email_address: "new-first@law.example")
    second = valid_registration(profile_url: old_url, resolved_profile_url: new_url,
      email_address: "old-second@law.example").merge(
        request_alternative_email: "1", alternative_email_address: "old-manual@law.example"
      )

    post registration_path(locale: :en), params: { registration: first }
    assert_redirected_to verification_status_path(locale: :en)
    counts = [ User.count, Session.count, Firm.count, Membership.count, LawyerProfile.count, Notification.count ]
    deliveries = ActionMailer::Base.deliveries.length
    assert_no_enqueued_jobs do
      post registration_path(locale: :en), params: { registration: second }
    end
    assert_response :unprocessable_content
    assert_equal counts, [ User.count, Session.count, Firm.count, Membership.count, LawyerProfile.count, Notification.count ]
    assert_equal deliveries, ActionMailer::Base.deliveries.length
  end

  test "separate pending profiles receive unique opaque bar numbers" do
    first = valid_registration
    second = valid_registration(
      first_name: "Grace", last_name: "Hopper", email_address: "grace@law.example",
      profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111"
    )

    assert_difference "LawyerProfile.count", 2 do
      post registration_path(locale: :en), params: { registration: first }
      post registration_path(locale: :en), params: { registration: second }
    end

    profiles = LawyerProfile.order(:id).last(2)
    assert_equal [ first[:directory_profile_url], second[:directory_profile_url] ], profiles.pluck(:directory_profile_url).uniq
    assert_not_equal profiles.first.bar_number, profiles.second.bar_number
    assert profiles.all? { |profile| profile.bar_number.start_with?("PENDING-") }
  end

  test "accounts receive separate workspaces without a supplied company identity" do
    first = valid_registration
    second = valid_registration(first_name: "Grace", last_name: "Hopper", email_address: "grace@law.example",
      profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/11111111-1111-4111-8111-111111111111")

    assert_difference [ "User.count", "Firm.count", "Membership.count" ], 2 do
      post registration_path(locale: :en), params: { registration: first }
      post registration_path(locale: :en), params: { registration: second }
    end

    first_user = User.find_by!(email_address: first[:email_address])
    second_user = User.find_by!(email_address: second[:email_address])
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, first_user.primary_firm.name
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, second_user.primary_firm.name
    assert_not_equal first_user.primary_firm.id, second_user.primary_firm.id
    assert_equal [ first_user.id ], first_user.primary_firm.user_ids
    assert_equal [ second_user.id ], second_user.primary_firm.user_ids
  end

  test "ignores forged legacy company and billing attributes including a lookup token" do
    original = BusinessRegistry::Preview.method(:apply)
    BusinessRegistry::Preview.define_singleton_method(:apply) { |*| raise "Registration must not apply company details" }
    assert_difference "Firm.count", 1 do
      post registration_path(locale: :en), params: {
        registration: valid_registration.merge(
          firm_name: "Forged Legal", enterprise_number: "invalid", vat_number: "BE0000000000",
          billing_email: "billing@example.test", phone: "+3225550199", address_line_1: "Private street 10",
          postal_code: "1000", city: "Brussels", kbo_lookup_token: "forged-token"
        )
      }
    end

    assert_redirected_to verification_status_path(locale: :en)
    firm = User.order(:id).last.primary_firm
    assert_equal Firm::INTERNAL_WORKSPACE_NAME, firm.name
    %w[enterprise_number vat_number billing_email phone address_line_1 postal_code city].each do |attribute|
      assert_nil firm.public_send(attribute), attribute
    end
    assert_empty firm.kbo_details
  ensure
    BusinessRegistry::Preview.define_singleton_method(:apply, original) if original
  end

  test "the listed email is authoritative even when another email is posted" do
    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(email_address: "forged@example.test") }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "ada@law.example", User.order(:id).last.email_address
    assert_nil User.find_by(email_address: "forged@example.test")
    assert_not User.order(:id).last.email_verified?
  end

  test "the signed directory identity is authoritative without posted names" do
    attributes = valid_registration.except(:first_name, :last_name)
    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: attributes }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "Ada Lovelace", User.order(:id).last.full_name
  end

  test "forged names cannot override the signed directory identity" do
    attributes = valid_registration.merge(first_name: "Forged", last_name: "Identity")
    assert_difference "User.count", 1 do
      post registration_path(locale: :en), params: { registration: attributes }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal "Ada Lovelace", User.order(:id).last.full_name
    assert_not User.order(:id).last.marketplace_verified?
  end

  test "another inline email becomes the sign-in address and requires confirmation and manual review" do
    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      assert_enqueued_jobs 1, only: Directory::VerificationJob do
        assert_difference "User.count", 1 do
          post registration_path(locale: :en), params: { registration: valid_registration.merge(
            request_alternative_email: "1", alternative_email_address: "  WORKING-ALTERNATIVE@example.test  ", email_address: "forged-alternative@example.test",
            email_review_status: "approved", email_verified_at: Time.current) }
        end
      end
    end
    assert_redirected_to verification_status_path(locale: :en)
    user = User.order(:id).last
    assert_equal "working-alternative@example.test", user.email_address
    assert_equal user.email_address, user.lawyer_profile.professional_email
    assert_not user.email_verified?
    assert_not user.marketplace_verified?
    assert user.lawyer_profile.email_review_pending?
    assert_equal user.email_address, user.lawyer_profile.email_review_email_address
    assert_not_nil user.lawyer_profile.email_review_requested_at
    assert_nil user.lawyer_profile.email_review_request_reason
    assert_nil user.lawyer_profile.directory_email_verified_at
    assert AuditEvent.exists?(auditable: user.lawyer_profile, actor_user: user, action: "email_access.requested")
    assert cookies[:session_id]
    follow_redirect!
    assert_response :success
    assert_select "a", text: I18n.t("email_access.status.provide_reason", locale: :en), count: 0
  end

  test "an alternative email choice does not bypass the signed profile or legal acceptance" do
    [ valid_registration.except(:directory_preview_token), valid_registration.merge(terms_accepted: "0") ].each do |attributes|
      assert_no_difference [ "User.count", "Firm.count", "LawyerProfile.count" ] do
        assert_no_enqueued_jobs do
          post registration_path(locale: :en), params: { registration: attributes.merge(
            request_alternative_email: "1", alternative_email_address: "blocked-alternative@example.test") }
        end
      end
      assert_response :unprocessable_content
    end
  end

  test "a failed directory enqueue preserves the pending inline email review and its confirmation" do
    original = Directory::VerificationJob.method(:perform_later)
    Directory::VerificationJob.define_singleton_method(:perform_later) { |*| raise ActiveJob::EnqueueError, "private adapter details" }
    assert_enqueued_jobs 1, only: EmailVerificationDeliveryJob do
      post registration_path(locale: :en), params: { registration: valid_registration.merge(
        request_alternative_email: "1", alternative_email_address: "queued-alternative@example.test") }
    end
    assert_redirected_to verification_status_path(locale: :en)
    assert_equal I18n.t("auth.registration.delivery_delayed", locale: :en), flash[:alert]
    assert cookies[:session_id]
  ensure
    Directory::VerificationJob.define_singleton_method(:perform_later, original) if original
  end

  test "alternate signup cannot reuse a signed preview for another profile or a forged token" do
    attributes = valid_registration.merge(request_alternative_email: "1", alternative_email_address: "blocked-preview@example.test")
    [ attributes.merge(directory_preview_token: "forged-preview"),
      attributes.merge(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}") ].each do |parameters|
      assert_no_difference [ "User.count", "Firm.count", "LawyerProfile.count", "AuditEvent.count" ] do
        assert_no_enqueued_jobs do
          post registration_path(locale: :en), params: { registration: parameters }
        end
      end
      assert_response :unprocessable_content
      assert_includes response.body, I18n.t("signup_profile.errors.invalid_preview", locale: :en)
    end
  end

  test "invalid missing duplicate and overlong alternate addresses never create partial accounts or send mail" do
    [ nil, " ", "invalid", users(:one).email_address, "x" * 250 + "@x.test" ].each do |email|
      assert_no_difference [ "User.count", "Firm.count", "Membership.count", "LawyerProfile.count", "AuditEvent.count" ] do
        assert_no_enqueued_jobs do
          post registration_path(locale: :en), params: { registration: valid_registration.merge(
            request_alternative_email: "1", alternative_email_address: email) }
        end
      end
      assert_response :unprocessable_content
      assert_select "input[name='registration[alternative_email_address]']"
    end
  end

  test "an unchecked alternate address is ignored and the listed address remains authoritative" do
    post registration_path(locale: :en), params: { registration: valid_registration.merge(
      request_alternative_email: "0", alternative_email_address: "ignored@example.test") }
    assert_redirected_to verification_status_path(locale: :en)
    user = User.order(:id).last
    assert_equal "ada@law.example", user.email_address
    assert_nil user.lawyer_profile.email_review_status
  end

  test "selecting the same listed address does not create a redundant review" do
    post registration_path(locale: :en), params: { registration: valid_registration.merge(
      request_alternative_email: "1", alternative_email_address: " ADA@LAW.EXAMPLE ") }
    assert_redirected_to verification_status_path(locale: :en)
    assert_nil User.order(:id).last.lawyer_profile.email_review_status
  end

  test "signup cannot use an arbitrary email without a signed directory result" do
    assert_no_difference [ "User.count", "Firm.count", "LawyerProfile.count" ] do
      post registration_path(locale: :en), params: { registration: valid_registration.except(:directory_preview_token) }
    end
    assert_response :unprocessable_content
    assert_includes response.body, I18n.t("signup_profile.errors.invalid_preview", locale: :en)
    assert_select "input[name='registration[email_address]']", count: 0
  end

  private

  def with_failed_verification_email(result: nil)
    original = EmailVerificationMailer.method(:verify)
    delivery = Object.new
    delivery.define_singleton_method(:deliver_later) do
      raise ActiveJob::EnqueueError, "private adapter details" unless result == false

      false
    end
    EmailVerificationMailer.define_singleton_method(:verify) { |*| delivery }
    yield
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  def valid_registration(first_name: "Ada", last_name: "Lovelace", email_address: "ada@law.example", profile_url: nil, resolved_profile_url: nil)
    url = profile_url || "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    result = Directory::SignupProfile::Result.new(status: :ok,
      profile_url: Directory::AdvocaatBeProfileLookup.canonical_profile_url(resolved_profile_url || url), original_profile_url: url,
      name: "#{first_name} #{last_name}", first_name:, last_name:, email_address:, profile_attributes: {})
    {
      first_name:,
      last_name:,
      email_address:,
      password: "correct-horse-battery-staple",
      password_confirmation: "correct-horse-battery-staple",
      directory_profile_url: url,
      directory_preview_token: Directory::SignupPreview.issue(result),
      locale: "en",
      terms_accepted: "1"
    }
  end
end
