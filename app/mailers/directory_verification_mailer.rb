class DirectoryVerificationMailer < ApplicationMailer
  def confirm(profile)
    @profile = profile
    @user = profile.user
    @login_email = @user.email_address
    @confirmation_url = directory_verification_url(
      token: Directory::ConfirmationToken.generate(profile), locale: @user.locale
    )

    I18n.with_locale(@user.locale) do
      mail(to: profile.directory_email, subject: t("directory_mail.confirm.subject"))
    end
  end
end
