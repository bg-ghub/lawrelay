class EmailVerificationMailer < ApplicationMailer
  def verify(user)
    @user = user
    @verification_url = email_verification_url(
      token: user.email_verification_token,
      locale: user.locale,
      **SiteHosts.account_url_options(user)
    )

    I18n.with_locale(user.locale) do
      mail(to: user.email_address, subject: t("auth.mailers.email_verification.subject"))
    end
  end
end
