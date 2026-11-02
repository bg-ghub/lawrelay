class AccountDeletionMailer < ApplicationMailer
  def requested(request)
    build_notice(request, "requested")
  end

  def cancelled(request)
    build_notice(request, "cancelled")
  end

  private

  def build_notice(request, kind)
    @request = request
    @user = request.user.reload
    return unless request.notice_eligible?(kind, user: @user)

    @kind = kind
    @login_url = new_session_url(locale: @user.locale, host: SiteHosts.app_host, protocol: SiteHosts.protocol)
    I18n.with_locale(@user.locale) do
      @date = I18n.l(request.scheduled_at.in_time_zone("Europe/Brussels").to_date, format: :long)
      mail(to: @user.email_address, subject: t("account_deletion_mail.#{kind}.subject"), template_name: "notice")
    end
  end
end
