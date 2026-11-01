class ConfirmationResendMailer < ApplicationMailer
  DOMAIN_FORMAT = /\A[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?\z/i

  def self.alertable_event?(event)
    return false unless event.is_a?(AuditEvent) && event.action == "account.confirmation_resend_requested" &&
      event.auditable_type == "User" && event.actor_user_id == event.auditable_id

    member = event.auditable
    member && !member.system_admin? && !member.erased_at &&
      event.metadata["recipient_domain"].is_a?(String) && DOMAIN_FORMAT.match?(event.metadata["recipient_domain"]) &&
      [ true, false ].include?(event.metadata["delivery_queued"])
  end

  def requested(event)
    return unless self.class.alertable_event?(event)

    @member = event.auditable
    @recipient_domain = event.metadata.fetch("recipient_domain").downcase
    @delivery_queued = event.metadata.fetch("delivery_queued")
    administrator = Admin::LoginAccount.account
    locale = administrator&.active? ? administrator.locale : :nl
    I18n.with_locale(locale) do
      @review_url = admin_user_url(@member, locale: locale, host: SiteHosts.admin_host, protocol: SiteHosts.protocol)
      mail(to: PlatformOperator.details[:support_email], subject: t("confirmation_resend.subject"))
    end
  end
end
