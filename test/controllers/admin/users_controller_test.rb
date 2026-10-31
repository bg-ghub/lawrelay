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
    patch admin_user_path(@admin, locale: :fr), params: { user: { first_name: "Forged" } }
    assert_redirected_to "/fr"
    sign_in_as(@admin)
    get "/fr/admin/users"
    assert_redirected_to "/fr/admin/mfa/setup"
  end

  test "search finds member identity without duplicate rows and escapes SQL wildcard input" do
    second_firm = Firm.create!(name: "Second managed office")
    @user.memberships.create!(firm: second_firm, role: "member")
    get "/en/admin/users", params: { q: "managed" }
    assert_response :success
    assert_select "a[href='#{admin_user_path(@user, locale: :en)}']", minimum: 1
    assert_select ".admin-user-row", count: 1
    get "/en/admin/users", params: { q: second_firm.name }
    assert_response :success
    assert_select ".admin-user-row", count: 0
    get "/en/admin/users", params: { q: "%" }
    assert_response :success
    assert_select "a[href='#{admin_user_path(@user, locale: :en)}']", count: 0
  end

  test "administrator accounts are excluded from managed users and legacy role filters" do
    other_admin = User.create!(first_name: "Managed", last_name: "Administrator",
      email_address: "managed-administrator@example.test", password: "password1234", system_role: "admin")
    other_admin.memberships.create!(firm: @account.firm, role: "owner")

    [ {}, { role: "admin" }, { role: "member" } ].each do |filters|
      get "/en/admin/users", params: filters
      assert_response :success
      assert_select ".admin-users-total", text: I18n.t("admin.users.index.total", count: User.where(system_role: "member").count, locale: :en)
      assert_select ".admin-user-row a[href='#{admin_user_path(@user, locale: :en)}']", minimum: 1
      [ @admin, other_admin ].each do |administrator|
        assert_select ".admin-user-row a[href='#{admin_user_path(administrator, locale: :en)}']", count: 0
        assert_select ".admin-user-row .admin-user-identity p", text: administrator.email_address, count: 0
      end
      assert_select "select[name='role']", count: 0
    end

    get "/en/admin/users", params: { q: other_admin.email_address, role: "admin" }
    assert_response :success
    assert_select ".admin-user-row", count: 0
    assert_select ".admin-users-total", text: I18n.t("admin.users.index.total", count: 0, locale: :en)
  end

  test "administrator accounts have no managed user detail or mutation routes" do
    original_account = @admin.attributes.slice("first_name", "email_address", "password_digest", "admin_mfa_secret_ciphertext", "admin_mfa_enabled_at", "suspended_at")
    original_sessions = @admin.sessions.pluck(:id)

    get admin_user_path(@admin, locale: :en)
    assert_response :not_found
    assert_no_difference "AuditEvent.count" do
      patch admin_user_path(@admin, locale: :en), params: { user: { first_name: "Changed", email_address: "changed-admin@example.test" } }
      assert_response :not_found
      %w[suspend restore revoke_sessions].each do |action|
        patch public_send("#{action}_admin_user_path", @admin, locale: :en), params: { user_management: { reason: "Not a managed account" } }
        assert_response :not_found
      end
    end
    assert_equal original_account, @admin.reload.attributes.slice(*original_account.keys)
    assert_equal original_sessions, @admin.sessions.pluck(:id)
  end

  test "filters distinguish suspended accounts from verified lawyer profiles" do
    @user.update!(suspended_at: Time.current)
    get "/en/admin/users", params: { status: "suspended", verification: "verified", role: "member" }
    assert_response :success
    assert_select "a[href='#{admin_user_path(@user, locale: :en)}']", minimum: 1
    get "/en/admin/users", params: { status: "active" }
    assert_select "a[href='#{admin_user_path(@user, locale: :en)}']", count: 0
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
    User.create!(first_name: "Paginated", last_name: "Administrator", email_address: "paginated-admin@example.test", password: "password1234", system_role: "admin")
    get "/en/admin/users", params: { q: "Paginated", page: 1, role: "admin" }
    assert_response :success
    assert_select ".admin-user-row", count: 25
    assert_select ".admin-users-pagination a[href*='role=']", count: 0
    get "/en/admin/users", params: { q: "Paginated", page: 2 }
    assert_select ".admin-user-row", count: 1
    get "/en/admin/users", params: { q: "Paginated", page: 2, per_page: 50 }
    assert_select ".admin-user-row", count: 26
  end

  test "list and account details render in all interface languages" do
    @account.firm.update!(name: "Hidden Legal Company", enterprise_number: "0123456749",
      address_line_1: "Hidden Company Street 123", postal_code: "4321", city: "Hidden Company City",
      kbo_details: { "source" => "kbo", "fields" => %w[name enterprise_number], "status" => "active" })
    %w[nl fr de en].each do |locale|
      get "/#{locale}/admin/users"
      assert_response :success
      assert_not_includes response.body, "translation missing"
      assert_company_metadata_absent
      get admin_user_path(@user, locale:)
      assert_response :success
      assert_not_includes response.body, "translation missing"
      assert_company_metadata_absent
    end
  end

  test "email edits reverify identity and cannot elevate privileges" do
    public_id = @user.public_id
    assert_enqueued_emails 1 do
      patch admin_user_path(@user, locale: :en), params: {
        user: { email_address: "updated@example.test", locale: "fr", system_role: "admin", email_verified_at: Time.current, public_id: SecureRandom.uuid }
      }
    end
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal "updated@example.test", @user.reload.email_address
    assert_equal "member", @user.system_role
    assert_equal public_id, @user.public_id
    assert_nil @user.email_verified_at
    assert_equal "pending", @account.profile.reload.verification_status
  end

  test "suspend restore and revoke use audited explicit actions" do
    @user.sessions.create!
    patch suspend_admin_user_path(@user, locale: :en), params: { user_management: { reason: "Access investigation" } }
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert @user.reload.suspended?
    assert_empty @user.reload.sessions
    patch restore_admin_user_path(@user, locale: :en), params: { user_management: { reason: "Identity confirmed" } }
    assert @user.reload.active?
    @user.sessions.create!
    patch revoke_sessions_admin_user_path(@user, locale: :en), params: { user_management: { reason: "Requested sign-out" } }
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_empty @user.reload.sessions
    assert_equal 3, AuditEvent.where(auditable: @user).count
  end

  test "a managed email correction remains saved when verification mail cannot be queued" do
    original = EmailVerificationMailer.method(:verify)
    EmailVerificationMailer.define_singleton_method(:verify) { |*| raise ActiveJob::EnqueueError, "private mail failure" }
    patch admin_user_path(@user, locale: :en), params: { user: { email_address: "admin-corrected@example.test" } }
    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal "admin-corrected@example.test", @user.reload.email_address
    assert_not @user.email_verified?
    assert_equal I18n.t("admin.users.notices.updated", locale: :en), flash[:notice]
    assert_equal I18n.t("auth.verification_status.queue_unavailable", locale: :en), flash[:alert]
  ensure
    EmailVerificationMailer.define_singleton_method(:verify, original) if original
  end

  test "missing reasons return validation errors" do
    patch suspend_admin_user_path(@user, locale: :en), params: { user_management: { reason: " " } }
    assert_response :unprocessable_content
    assert_select "a[hreflang='fr'][href='#{admin_user_path(@user, locale: :fr)}']", count: 1
    assert @user.reload.active?
  end

  test "invalid user fields are shown without partially updating identity" do
    patch admin_user_path(@user, locale: :en), params: { user: { email_address: "invalid" } }
    assert_response :unprocessable_content
    assert @user.reload.email_verified?
    assert @account.profile.reload.verified?
  end

  test "numeric bookmarks require administrator MFA before redirecting to the canonical UUID" do
    legacy_path = admin_user_path(@user.id, locale: :fr)
    sign_out
    get legacy_path
    assert_redirected_to admin_login_path(locale: :fr)
    sign_in_as(@user)
    get legacy_path
    assert_redirected_to root_path(locale: :fr)
    sign_in_as(@admin)
    get legacy_path
    assert_redirected_to admin_mfa_setup_path(locale: :fr)

    sign_in_as(@admin, admin_mfa: true)
    original_account = @user.reload.attributes
    assert_no_difference "AuditEvent.count" do
      get legacy_path
      assert_response :moved_permanently
      assert_redirected_to admin_user_path(@user, locale: :fr)
      assert_equal "no-store", response.headers["Cache-Control"]
      follow_redirect!
      assert_response :success
      head legacy_path
      assert_response :moved_permanently
      assert_redirected_to admin_user_path(@user, locale: :fr)
    end
    assert_equal original_account, @user.reload.attributes
  end

  test "another member cannot read or edit accounts through UUIDs or legacy IDs" do
    other_member = create_marketplace_account(prefix: "unauthorized-member").user
    original_account = @user.reload.attributes
    identifiers = [ @user.public_id, @user.id, SecureRandom.uuid ]

    [ nil, other_member, @admin ].each do |actor|
      actor ? sign_in_as(actor) : sign_out
      expected_path = if actor.nil?
        admin_login_path(locale: :en)
      elsif actor.system_admin?
        admin_mfa_setup_path(locale: :en)
      else
        root_path(locale: :en)
      end

      identifiers.each do |identifier|
        assert_no_difference "AuditEvent.count" do
          get admin_user_path(identifier, locale: :en)
          assert_redirected_to expected_path
          patch admin_user_path(identifier, locale: :en), params: { user: { first_name: "Forged" } }
          assert_redirected_to expected_path
        end
      end
    end

    assert_equal original_account, @user.reload.attributes
  end

  test "forms opened before the UUID migration remain bound to the same managed user" do
    other = create_marketplace_account(prefix: "legacy-form-other").user
    patch admin_user_path(@user.id, locale: :en), params: { user: { locale: "de", public_id: other.public_id } }

    assert_redirected_to admin_user_path(@user, locale: :en)
    assert_equal "de", @user.reload.locale
    assert_not_equal other.public_id, @user.public_id
    assert_equal "en", other.reload.locale
  end

  test "unknown UUIDs and malformed identifiers never fall back to a numeric prefix" do
    [ SecureRandom.uuid, "#{@user.id}extra", "0#{@user.id}", @user.public_id.delete("-") ].each do |identifier|
      get admin_user_path(identifier, locale: :en)
      assert_response :not_found
      assert_no_difference "AuditEvent.count" do
        patch admin_user_path(identifier, locale: :en), params: { user: { first_name: "Forged" } }
      end
      assert_response :not_found
    end
    assert_equal "Managed", @user.reload.first_name
  end

  private

  def assert_company_metadata_absent
    [ @account.firm.name, @account.firm.enterprise_number, @account.firm.vat_number,
      @account.firm.address_line_1, @account.firm.city ].each do |value|
      assert_not_includes response.body, value
    end
    assert_select ".business-source", count: 0
  end
end
