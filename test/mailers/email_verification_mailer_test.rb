require "test_helper"

class EmailVerificationMailerTest < ActionMailer::TestCase
  test "sends a localized expiring verification link" do
    user = users(:two)
    user.update!(locale: "nl", email_verified_at: nil)

    email = EmailVerificationMailer.verify(user)

    assert_equal [ user.email_address ], email.to
    assert_equal "Bevestig uw LawRelay-e-mailadres", email.subject
    assert_match %r{/nl/email-verification/}, email.body.encoded
    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, "Geachte Mr. #{user.last_name},"
    end
  end

  test "Dutch administrator mail uses the full name without a lawyer title" do
    user = users(:two)
    user.update!(locale: "nl", system_role: "admin", email_verified_at: nil)

    email = EmailVerificationMailer.verify(user)

    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, "Geachte #{user.full_name},"
      assert_not_includes part.body.decoded, "Geachte Mr."
    end
  end
end
