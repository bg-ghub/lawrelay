class PasswordsMailer < ApplicationMailer
  def reset(user)
    @user = user
    @reset_url = edit_password_url(token: user.password_reset_token, locale: user.locale)

    I18n.with_locale(user.locale) do
      mail subject: t("auth.mailers.password_reset.subject"), to: user.email_address
    end
  end
end
