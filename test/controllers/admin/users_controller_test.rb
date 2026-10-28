require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @account = create_marketplace_account(prefix: "managed")
    @user = @account.user
    sign_in_as(@admin, admin_mfa: true)
  end

  test "user management requires administrator role and fresh MFA" do
    sign_out
    get "/fr/admin/users"
    assert_redirected_to "/fr/admin/login"
    sign_in_as(@user)
    get "/fr/admin/users"
    assert_redirected_to "/fr"
    patch "/fr/admin/users/#{@admin.id}", params: { user: { first_name: "Forged" } }
    assert_redirected_to "/fr"
    sign_in_as(@admin)
    get "/fr/admin/users"
    assert_redirected_to "/fr/admin/mfa/setup"
  end

  test "search finds firm members without duplicate rows and escapes SQL wildcard input" do
    second_firm = Firm.create!(name: "Second managed office")
    @user.memberships.create!(firm: second_firm, role: "member")
    get "/en/admin/users", params: { q: "managed" }
    assert_response :success
    assert_select "a[href='/en/admin/users/#{@user.id}']", minimum: 1
    assert_select ".admin-user-row", count: 1
    get "/en/admin/users", params: { q: "%" }
    assert_response :success
    assert_select "a[href='/en/admin/users/#{@user.id}']", count: 0
  end

  test "filters distinguish suspended accounts from verified lawyer profiles" do
    @user.update!(suspended_at: Time.current)
    get "/en/admin/users", params: { status: "suspended", verification: "verified", role: "member" }
    assert_response :success
    assert_select "a[href='/en/admin/users/#{@user.id}']", minimum: 1
    get "/en/admin/users", params: { status: "active" }
    assert_select "a[href='/en/admin/users/#{@user.id}']", count: 0
  end

  test "pagination clamps untrusted page and page size" do
    get "/en/admin/users", params: { page: "9999999999999999999999999", per_page: "1000000" }
    assert_response :success
    assert_includes response.body, @user.email_address
  end

  test "pagination returns bounded pages without dropping or duplicating search matches" do
    26.times do |index|
      User.create!(first_name: "Paginated", last_name: "Lawyer #{index}", email_address: "paginated-#{index}@example.test", password: "password1234")
    end
    get "/en/admin/users", params: { q: "Paginated", page: 1 }
    assert_response :success
    assert_select ".admin-user-row", count: 25
    get "/en/admin/users", params: { q: "Paginated", page: 2 }
    assert_select ".admin-user-row", count: 1
    get "/en/admin/users", params: { q: "Paginated", page: 2, per_page: 50 }
    assert_select ".admin-user-row", count: 26
  end

  test "list and account details render in all interface languages" do
    %w[nl fr de en].each do |locale|
      get "/#{locale}/admin/users"
      assert_response :success
      assert_not_includes response.body, "translation missing"
      get "/#{locale}/admin/users/#{@user.id}"
      assert_response :success
      assert_not_includes response.body, "translation missing"
    end
  end

  test "email edits reverify identity and cannot elevate privileges" do
    assert_enqueued_emails 1 do
      patch "/en/admin/users/#{@user.id}", params: {
        user: { email_address: "updated@example.test", locale: "fr", system_role: "admin", email_verified_at: Time.current }
      }
    end
    assert_redirected_to "/en/admin/users/#{@user.id}"
    assert_equal "updated@example.test", @user.reload.email_address
    assert_equal "member", @user.system_role
    assert_nil @user.email_verified_at
    assert_equal "pending", @account.profile.reload.verification_status
  end

  test "suspend restore and revoke use audited explicit actions" do
    @user.sessions.create!
    patch "/en/admin/users/#{@user.id}/suspend", params: { user_management: { reason: "Access investigation" } }
    assert_redirected_to "/en/admin/users/#{@user.id}"
    assert @user.reload.suspended?
    assert_empty @user.reload.sessions
    patch "/en/admin/users/#{@user.id}/restore", params: { user_management: { reason: "Identity confirmed" } }
    assert @user.reload.active?
    @user.sessions.create!
    patch revoke_sessions_admin_user_path(@user, locale: :en), params: { user_management: { reason: "Requested sign-out" } }
    assert_redirected_to "/en/admin/users/#{@user.id}"
    assert_empty @user.reload.sessions
    assert_equal 3, AuditEvent.where(auditable: @user).count
  end

  test "missing reasons and protected operator updates return validation errors" do
    patch "/en/admin/users/#{@user.id}/suspend", params: { user_management: { reason: " " } }
    assert_response :unprocessable_content
    assert_select "a[hreflang='fr'][href='/fr/admin/users/#{@user.id}']", count: 1
    assert @user.reload.active?
    patch "/en/admin/users/#{@admin.id}", params: { user: { email_address: "changed-admin@example.test" } }
    assert_response :unprocessable_content
    assert_not_equal "changed-admin@example.test", @admin.reload.email_address
  end

  test "invalid user fields are shown without partially updating identity" do
    patch "/en/admin/users/#{@user.id}", params: { user: { email_address: "invalid" } }
    assert_response :unprocessable_content
    assert @user.reload.email_verified?
    assert @account.profile.reload.verified?
  end
end
