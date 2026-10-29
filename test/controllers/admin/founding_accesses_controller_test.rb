require "test_helper"

class Admin::FoundingAccessesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @previous_release_mode = ENV["LAWRELAY_RELEASE_MODE"]
    ENV["LAWRELAY_RELEASE_MODE"] = "paid"
    @admin = create_user(email: "admin-founding-access@example.test", system_role: "admin")
    configure_admin_mfa(@admin)
    @owner = create_user(email: "owner-founding-access@example.test")
    @firm = Firm.create!(
      name: "Verified Founding Firm",
      enterprise_number: "FOUNDING001",
      verification_status: "verified",
      verified_at: Time.current
    )
    @owner.memberships.create!(firm: @firm, role: "owner")
  end

  teardown do
    @previous_release_mode ? ENV["LAWRELAY_RELEASE_MODE"] = @previous_release_mode : ENV.delete("LAWRELAY_RELEASE_MODE")
  end

  test "beta redirects archived access controls without changing billing or audit records" do
    ENV["LAWRELAY_RELEASE_MODE"] = "beta"
    account = BillingAccount.create!(firm: @firm, status: "active", complimentary_access_until: 20.days.from_now)
    original_account = account.attributes
    sign_in_as(@admin, admin_mfa: true)

    assert_no_difference([ "BillingAccount.count", "Subscription.count", "Invoice.count", "BillingPayment.count", "AuditEvent.count" ]) do
      request_access_controls { assert_redirected_to "/en/admin/users" }
      post "/en/admin/founding_accesses", params: { firm_id: "missing" }
      assert_redirected_to "/en/admin/users"
      delete "/en/admin/founding_accesses/missing"
      assert_redirected_to "/en/admin/users"
    end
    assert_equal original_account, account.reload.attributes
  end

  test "archived beta controls still require an administrator and fresh MFA" do
    ENV["LAWRELAY_RELEASE_MODE"] = "beta"

    assert_no_difference([ "BillingAccount.count", "Subscription.count", "Invoice.count", "BillingPayment.count", "AuditEvent.count" ]) do
      request_access_controls { assert_redirected_to "/en/admin/login" }
      sign_in_as(@owner)
      request_access_controls { assert_redirected_to "/en" }
      sign_in_as(@admin)
      request_access_controls { assert_redirected_to "/en/admin/mfa/challenge" }
    end
  end

  test "MFA-verified system admin can view verified firms" do
    sign_in_as(@admin, admin_mfa: true)

    get "/en/admin/founding_accesses"

    assert_response :success
    assert_select "h2", @firm.name
    assert_select "body", text: /#{Regexp.escape(@owner.email_address)}/
  end

  test "system admin must complete MFA to access founding access" do
    sign_in_as(@admin)

    get "/en/admin/founding_accesses"

    assert_redirected_to "/en/admin/mfa/challenge"
  end

  test "grant creates a time-limited complimentary entitlement and audit event without billing records" do
    sign_in_as(@admin, admin_mfa: true)
    expires_on = 30.days.from_now.to_date

    assert_difference("BillingAccount.count", 1) do
      assert_difference("AuditEvent.count", 1) do
        assert_no_difference([ "Subscription.count", "Invoice.count", "BillingPayment.count" ]) do
          post "/en/admin/founding_accesses", params: {
            firm_id: @firm.id,
            founding_access: { expires_on: expires_on.iso8601 }
          }
        end
      end
    end

    assert_redirected_to "/en/admin/founding_accesses"
    account = @firm.reload.billing_account
    assert_equal "founding_beta", account.plan_key
    assert_equal "active", account.status
    assert_equal expires_on, account.complimentary_access_until.to_date
    assert account.posting_access?
    assert_equal "billing.founding_access_granted", AuditEvent.order(:id).last.action
  end

  test "rejects dates beyond one year and does not create billing records" do
    sign_in_as(@admin, admin_mfa: true)

    assert_no_difference([ "BillingAccount.count", "AuditEvent.count" ]) do
      post "/en/admin/founding_accesses", params: {
        firm_id: @firm.id,
        founding_access: { expires_on: 1.year.from_now.to_date.next_day.iso8601 }
      }
    end

    assert_redirected_to "/en/admin/founding_accesses"
    assert_equal "Choose an end date from today through one year from today.", flash[:alert]
  end

  test "does not grant access to an unverified firm" do
    unverified_firm = Firm.create!(name: "Unverified Firm", enterprise_number: "UNVERIFIED001")
    sign_in_as(@admin, admin_mfa: true)

    assert_no_difference([ "BillingAccount.count", "AuditEvent.count" ]) do
      post "/en/admin/founding_accesses", params: {
        firm_id: unverified_firm.id,
        founding_access: { expires_on: 30.days.from_now.to_date.iso8601 }
      }
    end

    assert_redirected_to "/en/admin/founding_accesses"
    assert_equal "Only verified firms can receive founding access.", flash[:alert]
  end

  test "does not replace a paid billing plan with complimentary access" do
    account = BillingAccount.create!(firm: @firm, plan_key: "lawrelay_office", status: "active")
    sign_in_as(@admin, admin_mfa: true)

    assert_no_difference("AuditEvent.count") do
      post "/en/admin/founding_accesses", params: {
        firm_id: @firm.id,
        founding_access: { expires_on: 30.days.from_now.to_date.iso8601 }
      }
    end

    assert_redirected_to "/en/admin/founding_accesses"
    assert_equal "lawrelay_office", account.reload.plan_key
    assert_equal "This firm already has a paid billing plan.", flash[:alert]
  end

  test "revoke removes access and records the decision" do
    account = BillingAccount.create!(
      firm: @firm,
      status: "active",
      complimentary_access_until: 20.days.from_now # gitleaks:allow (a test expiry, not an access credential)
    )
    sign_in_as(@admin, admin_mfa: true)

    assert_difference("AuditEvent.count", 1) do
      delete "/en/admin/founding_accesses/#{@firm.id}"
    end

    assert_redirected_to "/en/admin/founding_accesses"
    assert_nil account.reload.complimentary_access_until
    assert_equal "pending", account.status
    assert_not account.posting_access?
    assert_equal "billing.founding_access_revoked", AuditEvent.order(:id).last.action
  end

  private

  def request_access_controls
    get "/en/admin/founding_accesses"
    yield
    post "/en/admin/founding_accesses", params: {
      firm_id: @firm.id, founding_access: { expires_on: 30.days.from_now.to_date.iso8601 }
    }
    yield
    delete "/en/admin/founding_accesses/#{@firm.id}"
    yield
  end

  def create_user(email:, system_role: "member")
    User.create!(
      email_address: email,
      password: "password1234",
      first_name: "Founding",
      last_name: "Tester",
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
