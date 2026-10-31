class RegistryStatusMailer < ApplicationMailer
  def daily_alert(run)
    @findings_count = run.new_findings_count
    return if @findings_count.zero?

    administrator = Admin::LoginAccount.account
    locale = administrator&.active? ? administrator.locale : :nl
    I18n.with_locale(locale) do
      @review_url = admin_registry_statuses_url(locale: locale, host: SiteHosts.admin_host, protocol: SiteHosts.protocol)
      mail(to: PlatformOperator.details[:support_email], subject: I18n.t("registry_status.mailer.subject", count: @findings_count))
    end
  end
end
