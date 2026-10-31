require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::RegistryStatusesControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @account = create_marketplace_account(prefix: "register-review")
    @account.profile.update!(directory_profile_url: profile_url,
      directory_name: @account.user.full_name, directory_email: @account.user.email_address)
    sign_in_as(@admin, admin_mfa: true)
  end

  test "directory status requires administrator access and fresh MFA" do
    sign_out
    get "/fr/admin/registry-status"
    assert_redirected_to "/fr/admin/login"

    sign_in_as(@account.user)
    get "/fr/admin/registry-status"
    assert_redirected_to "/fr"

    sign_in_as(@admin)
    get "/fr/admin/registry-status"
    assert_redirected_to "/fr/admin/mfa/setup"
  end

  test "empty state and directory results render in all four languages" do
    %w[nl fr de en].each do |locale|
      get admin_registry_statuses_path(locale:)
      assert_response :success
      assert_select "h2", text: I18n.t("registry_status.empty_title", locale:)
      assert_not_includes response.body, "translation missing"
    end

    check = create_check("changed")
    check.record_result!(outcome: "unavailable", checked_at: Time.current, run_on: Date.current,
      identity_digest: check.identity_digest)
    RegistryStatusRun.create!(run_on: Date.current, status: "completed", checked_count: 1,
      started_at: 1.minute.ago, completed_at: Time.current, findings: [ check.finding_snapshot ])

    %w[nl fr de en].each do |locale|
      get admin_registry_statuses_path(locale:)
      assert_response :success
      assert_not_includes response.body, "translation missing"
      assert_select ".registry-status-check", count: 1
      assert_select "a[href='#{admin_user_path(@account.user, locale:)}']", count: 1
      assert_includes response.body, I18n.t("registry_status.statuses.directory.unavailable", locale:)
      assert_includes response.body, I18n.t("registry_status.issues.directory.changed", locale:)
      assert_includes response.body, I18n.t("registry_status.intro", locale:)
      assert_not_includes response.body, @account.firm.name
      assert_not_includes response.body, @account.firm.enterprise_number
      assert_select ".registry-status-check form", count: 0
    end
  end

  test "legacy company checks are hidden before the cleanup runs" do
    digest = RegistryStatusCheck.digest("kbo", @account.firm.enterprise_number)
    RegistryStatusCheck.new(source: "kbo", firm: @account.firm, target_digest: digest,
      identity_digest: digest, status: "inactive", issue_status: "inactive").save!(validate: false)
    create_check("active")

    %w[nl fr de en].each do |locale|
      get admin_registry_statuses_path(locale:)
      assert_response :success
      assert_select ".registry-status-check", count: 1
      assert_not_includes response.body, "KBO"
      assert_not_includes response.body, @account.firm.name
      assert_not_includes response.body, @account.firm.enterprise_number
    end
  end

  test "review links use public UUIDs and exclude outdated or erased identities" do
    create_check("not_listed")
    get admin_registry_statuses_path(locale: :en)
    assert_select "a[href='#{admin_user_path(@account.user, locale: :en)}']", count: 1
    assert_select "a[href='/en/admin/users/#{@account.user.id}']", count: 0

    @account.profile.update!(directory_profile_url: profile_url)
    get admin_registry_statuses_path(locale: :en)
    assert_select ".registry-status-check", count: 0
    assert_not_includes response.body, @account.user.full_name

    create_check("changed")
    @account.user.update!(erased_at: Time.current)
    get admin_registry_statuses_path(locale: :en)
    assert_select ".registry-status-check", count: 0
  end

  test "status rows are bounded to one hundred and untrusted page input is clamped" do
    101.times do |index|
      user = User.create!(first_name: "Directory", last_name: "Member #{index}",
        email_address: "directory-page-#{index}@example.test", password: "password1234")
      profile = user.create_lawyer_profile!(bar_association: "OVB", bar_number: "directory-page-#{index}",
        directory_profile_url: profile_url, directory_name: user.full_name, directory_email: user.email_address)
      create_check("active", profile:)
    end

    get admin_registry_statuses_path(locale: :en), params: { page: 1, per_page: 999_999 }
    assert_response :success
    assert_select ".registry-status-check", count: 100
    get admin_registry_statuses_path(locale: :en), params: { page: "999999999999999999999" }
    assert_response :success
    assert_select ".registry-status-check", count: 1
  end

  private

  def profile_url
    "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
  end

  def create_check(outcome, profile: @account.profile)
    target = RegistryStatus::Targets.all.find { |candidate| candidate.lawyer_profile_id == profile.id }
    check = RegistryStatusCheck.new(source: "directory", target_digest: target.digest, lawyer_profile: profile)
    check.record_result!(outcome:, checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    check
  end
end
