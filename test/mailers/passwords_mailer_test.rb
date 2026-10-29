require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "administrator reset mail is suppressed even for a stale object" do
    user = users(:one)
    stale_user = User.find(user.id)
    user.update!(system_role: "admin")

    assert_no_emails do
      PasswordsMailer.reset(stale_user).deliver_now
    end
    assert_nil PasswordsMailer.reset(user).to
  end

  test "sends a localized reset link with the locale and token in the right segments" do
    user = users(:one)
    user.update!(locale: "fr")

    email = PasswordsMailer.reset(user)

    assert_equal [ user.email_address ], email.to
    assert_equal "Réinitialisez votre mot de passe LawRelay", email.subject
    assert_match %r{/fr/passwords/.+/edit}, email.text_part.body.decoded
  end

  test "HTML and text expiry messages are translated in every interface language" do
    user = users(:one)
    {
      nl: [ "Herstel je LawRelay-wachtwoord", "15 minuten" ],
      fr: [ "Réinitialisez votre mot de passe LawRelay", "15 minutes" ],
      de: [ "LawRelay-Passwort zurücksetzen", "15 Minuten" ],
      en: [ "Reset your LawRelay password", "15 minutes" ]
    }.each do |locale, (subject, duration)|
      user.update!(locale:)
      email = I18n.with_locale(:en) { PasswordsMailer.reset(user).message }

      assert_equal subject, email.subject
      [ email.html_part, email.text_part ].each do |part|
        assert_includes part.body.decoded, duration
        assert_no_match(/translation missing/i, part.body.decoded)
        assert_match %r{/#{locale}/passwords/.+/edit}, part.body.decoded
      end
    end
  end

  test "the translated duration follows the configured expiry and handles a single minute" do
    user = users(:one)
    user.update!(locale: "nl")
    user.define_singleton_method(:password_reset_token_expires_in) { 1.minute }

    email = PasswordsMailer.reset(user)

    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, "over 1 minuut."
      assert_no_match(/translation missing/i, part.body.decoded)
    end
  end
end
