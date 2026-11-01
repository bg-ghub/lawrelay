require "test_helper"

class ConfirmationResendMailerTest < ActionMailer::TestCase
  setup do
    @member = users(:one)
    @admin = users(:two)
    @admin.update!(system_role: "admin")
    @event = AuditEvent.create!(auditable: @member, actor_user: @member,
      action: "account.confirmation_resend_requested", metadata: { recipient_domain: "advocaat.be", delivery_queued: true,
        ignored_private_details: "PRIVATE-DETAILS-NOT-FOR-EMAIL" })
  end

  test "operator receives the member domain and protected UUID review link in their own locale" do
    %w[nl fr de en].each do |locale|
      @admin.update!(locale:)
      email = I18n.with_locale(:en) { ConfirmationResendMailer.requested(@event).message }

      assert_equal [ PlatformOperator.details[:support_email] ], email.to
      assert_nil email.cc
      assert_nil email.bcc
      assert_equal I18n.t("confirmation_resend.subject", locale:), email.subject
      [ email.html_part, email.text_part ].each do |part|
        body = part.body.decoded
        assert_includes body, "advocaat.be"
        assert_includes body, "#{SiteHosts.protocol}://#{SiteHosts.admin_host}/#{locale}/admin/users/#{@member.public_id}"
        assert_includes body, I18n.t("confirmation_resend.queued", locale:)
        assert_includes body, I18n.t("confirmation_resend.delivery_note", locale:)
        assert_not_includes body, @member.email_address
        assert_not_includes body, "PRIVATE-DETAILS-NOT-FOR-EMAIL"
        assert_not_includes body, "/email-verification/"
        assert_not_includes body, "/passwords/"
        assert_no_match(/translation missing/i, body)
      end
    end
  end

  test "failed confirmation enqueue is identified without describing a remote rejection" do
    @admin.update!(locale: "nl")
    @event.update!(metadata: @event.metadata.merge("delivery_queued" => false))
    email = ConfirmationResendMailer.requested(@event)

    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, I18n.t("confirmation_resend.not_queued", locale: :nl)
      assert_includes part.body.decoded, I18n.t("confirmation_resend.delivery_note", locale: :nl)
    end
  end

  test "missing or inactive operator account falls back to Dutch" do
    original = Admin::LoginAccount.method(:account)
    Admin::LoginAccount.define_singleton_method(:account) { nil }
    assert_equal I18n.t("confirmation_resend.subject", locale: :nl), ConfirmationResendMailer.requested(@event).subject

    @admin.update!(locale: "fr", suspended_at: Time.current)
    administrator = @admin
    Admin::LoginAccount.define_singleton_method(:account) { administrator }
    assert_equal I18n.t("confirmation_resend.subject", locale: :nl), ConfirmationResendMailer.requested(@event).subject
  ensure
    Admin::LoginAccount.define_singleton_method(:account, original) if original
  end

  test "unrelated events, malformed domains and administrator or erased subjects are rejected" do
    assert_no_emails do
      @event.update!(action: "account.updated")
      ConfirmationResendMailer.requested(@event).deliver_now
      @event.update!(action: "account.confirmation_resend_requested", metadata: { recipient_domain: "private@example.test", delivery_queued: true })
      ConfirmationResendMailer.requested(@event).deliver_now
      @event.update!(metadata: { recipient_domain: "advocaat.be", delivery_queued: true }, actor_user: @admin)
      ConfirmationResendMailer.requested(@event).deliver_now
      @event.update!(actor_user: @member)
      @member.update!(system_role: "admin")
      ConfirmationResendMailer.requested(@event).deliver_now
      @member.update!(system_role: "member", erased_at: Time.current)
      ConfirmationResendMailer.requested(@event).deliver_now
    end
  end
end
