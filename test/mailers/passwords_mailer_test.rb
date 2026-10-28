require "test_helper"

class PasswordsMailerTest < ActionMailer::TestCase
  test "sends a localized reset link with the locale and token in the right segments" do
    user = users(:one)
    user.update!(locale: "fr")

    email = PasswordsMailer.reset(user)

    assert_equal [ user.email_address ], email.to
    assert_equal "Réinitialisez votre mot de passe LawRelay", email.subject
    assert_match %r{/fr/passwords/.+/edit}, email.text_part.body.decoded
  end
end
