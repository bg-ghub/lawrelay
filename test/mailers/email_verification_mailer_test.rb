require "test_helper"

class EmailVerificationMailerTest < ActionMailer::TestCase
  test "sends a localized expiring verification link" do
    user = users(:two)
    user.update!(locale: "nl", email_verified_at: nil)

    email = EmailVerificationMailer.verify(user)

    assert_equal [ user.email_address ], email.to
    assert_equal "Bevestig je LawRelay-e-mailadres", email.subject
    assert_match %r{/nl/email-verification/}, email.body.encoded
  end
end
