require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Admin::RegistryStatusesControllerTest < ActionDispatch::IntegrationTest
  include MarketplaceTestFactory

  setup do
    @admin = users(:one)
    @admin.update!(system_role: "admin")
    @account = create_marketplace_account(prefix: "register-review")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @account.user.full_name, directory_email: @account.user.email_address)
    sign_in_as(@admin, admin_mfa: true)
  end

  test "register status requires administrator access and fresh MFA" do
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

  test "empty state and populated results render in all four languages" do
    %w[nl fr de en].each do |locale|
      get admin_registry_statuses_path(locale:)
      assert_response :success
      assert_select "h2", text: I18n.t("registry_status.empty_title", locale:)
      assert_not_includes response.body, "translation missing"
    end

    kbo_check = create_check("kbo", "inactive")
    directory_check = create_check("directory", "changed")
    directory_check.record_result!(outcome: "unavailable", checked_at: Time.current, run_on: Date.current,
      identity_digest: directory_check.identity_digest)
    RegistryStatusRun.create!(run_on: Date.current, status: "completed", checked_count: 2,
      started_at: 1.minute.ago, completed_at: Time.current, findings: [ kbo_check.finding_snapshot ])

    %w[nl fr de en].each do |locale|
      get admin_registry_statuses_path(locale:)
      assert_response :success
      assert_not_includes response.body, "translation missing"
      assert_select ".registry-status-check", count: 2
      assert_select "a[href='#{admin_user_path(@account.user, locale:)}']", count: 2
      assert_includes response.body, I18n.t("registry_status.statuses.directory.unavailable", locale:)
      assert_includes response.body, I18n.t("registry_status.issues.directory.changed", locale:)
      assert_select ".registry-status-check form", count: 0
    end
  end

  test "uncertain KBO results are not presented as an inactive company" do
    check = create_check("kbo", "unavailable")
    %w[unavailable not_found invalid pending ok].each do |status|
      check.update!(status:)
      get admin_registry_statuses_path(locale: :en)
      assert_response :success
      assert_includes response.body, I18n.t("registry_status.statuses.kbo.#{status}", locale: :en)
      assert_not_includes response.body, I18n.t("registry_status.statuses.kbo.inactive", locale: :en)
      assert_not_includes response.body, I18n.t("registry_status.issues.kbo.inactive", locale: :en)
    end
  end

  test "review links use public UUIDs and exclude outdated or erased identities" do
    create_check("kbo", "inactive")
    create_check("directory", "not_listed")
    get admin_registry_statuses_path(locale: :en)
    assert_select "a[href='#{admin_user_path(@account.user, locale: :en)}']", count: 2
    assert_select "a[href='/en/admin/users/#{@account.user.id}']", count: 0

    @account.firm.update!(enterprise_number: "0123456749")
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}")
    get admin_registry_statuses_path(locale: :en)
    assert_select ".registry-status-check", count: 0
    assert_not_includes response.body, @account.user.full_name

    @account.user.update!(erased_at: Time.current)
    get admin_registry_statuses_path(locale: :en)
    assert_select ".registry-status-check", count: 0
  end

  test "status rows are bounded to one hundred and untrusted page input is clamped" do
    101.times do |index|
      base = 1_000_000 + index
      number = format("%08d%02d", base, 97 - (base % 97))
      firm = Firm.create!(name: "Register office #{index}", enterprise_number: number)
      @account.user.memberships.create!(firm:, role: "member")
      digest = RegistryStatusCheck.digest("kbo", number)
      RegistryStatusCheck.create!(source: "kbo", firm:, target_digest: digest, identity_digest: digest,
        status: "ok", checked_at: Time.current)
    end

    get admin_registry_statuses_path(locale: :en), params: { page: 1, per_page: 999_999 }
    assert_response :success
    assert_select ".registry-status-check", count: 100
    get admin_registry_statuses_path(locale: :en), params: { page: "999999999999999999999" }
    assert_response :success
    assert_select ".registry-status-check", count: 1
  end

  private

  def create_check(source, outcome)
    target = RegistryStatus::Targets.all.find do |candidate|
      candidate.source == source && (candidate.firm_id == @account.firm.id || candidate.lawyer_profile_id == @account.profile.id)
    end
    check = RegistryStatusCheck.new(source:, target_digest: target.digest,
      firm_id: target.firm_id, lawyer_profile_id: target.lawyer_profile_id)
    check.record_result!(outcome:, checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    check
  end
end
