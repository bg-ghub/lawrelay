class EmailAccessReviewMailer < ApplicationMailer
  def decision(profile)
    @profile = profile
    @user = profile.user
    @review_url = verification_status_url(locale: @user.locale, **SiteHosts.account_url_options(@user))
    I18n.with_locale(@user.locale) do
      mail(to: @user.email_address, subject: t("email_access.mailer.subject.#{profile.email_review_status}"))
    end
  end
end
