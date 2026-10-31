require "test_helper"
require_relative "../support/marketplace_test_factory"

class RegistryStatusMailerTest < ActionMailer::TestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "private-register-identity")
    target = RegistryStatus::Targets.all.find { |candidate| candidate.source == "kbo" && candidate.firm_id == @account.firm.id }
    @check = RegistryStatusCheck.new(source: "kbo", target_digest: target.digest, firm: @account.firm)
    @check.record_result!(outcome: "inactive", checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    @run = RegistryStatusRun.create!(run_on: Date.current, status: "completed", completed_at: Time.current,
      findings: [ @check.finding_snapshot ])
    @admin = users(:one)
    @admin.update!(system_role: "admin")
  end

  test "one summary goes to the operator in the active administrator locale with only a secure review link" do
    @account.profile.update!(directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @account.user.full_name, directory_email: "private-directory@example.test")
    target = RegistryStatus::Targets.all.find { |candidate| candidate.source == "directory" && candidate.lawyer_profile_id == @account.profile.id }
    directory_check = RegistryStatusCheck.new(source: "directory", target_digest: target.digest, lawyer_profile: @account.profile)
    directory_check.record_result!(outcome: "changed", checked_at: Time.current, run_on: Date.current, identity_digest: target.identity_digest)
    @run.update!(findings: [ @check.finding_snapshot, directory_check.finding_snapshot ])

    %w[nl fr de en].each do |locale|
      @admin.update!(locale:)
      email = RegistryStatusMailer.daily_alert(@run)
      assert_equal [ PlatformOperator.details[:support_email] ], email.to
      assert_nil email.cc
      assert_nil email.bcc
      assert_equal I18n.t("registry_status.mailer.subject", count: 2, locale:), email.subject

      [ email.html_part.body.decoded, email.text_part.body.decoded ].each do |body|
        assert_includes body, "#{SiteHosts.protocol}://#{SiteHosts.admin_host}/#{locale}/admin/registry-status"
        assert_includes body, I18n.t("registry_status.mailer.body", count: 2, locale:)
        [ @account.user.full_name, @account.user.email_address, @account.firm.name, @account.firm.enterprise_number,
          @account.user.public_id, @account.profile.directory_email, @account.profile.directory_profile_url ].each do |private_value|
          assert_not_includes body, private_value
        end
      end
    end
  end

  test "missing or inactive configured administrator falls back to Dutch" do
    original = Admin::LoginAccount.method(:account)
    Admin::LoginAccount.define_singleton_method(:account) { nil }
    assert_equal I18n.t("registry_status.mailer.subject", count: 1, locale: :nl), RegistryStatusMailer.daily_alert(@run).subject

    @admin.update!(locale: "fr", suspended_at: Time.current)
    administrator = @admin
    Admin::LoginAccount.define_singleton_method(:account) { administrator }
    assert_equal I18n.t("registry_status.mailer.subject", count: 1, locale: :nl), RegistryStatusMailer.daily_alert(@run).subject
  ensure
    Admin::LoginAccount.define_singleton_method(:account, original) if original
  end

  test "source findings removed or no longer relevant do not produce a summary" do
    @account.user.update!(erased_at: Time.current)
    assert_emails 0 do
      RegistryStatusMailer.daily_alert(@run).deliver_now
    end

    @run.update!(findings: [])
    assert_emails 0 do
      RegistryStatusMailer.daily_alert(@run).deliver_now
    end
  end
end
