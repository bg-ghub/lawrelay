require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "long password errors are translated in all interface languages" do
    user = users(:one)
    %i[nl fr de en].each do |locale|
      I18n.with_locale(locale) do
        assert_not user.update(password: "x" * 80)
        assert user.errors.of_kind?(:password, :password_too_long)
        assert_not user.errors.full_messages.join.match?(/translation missing/i)
      end
    end
  end

  test "an administrator is not a marketplace participant even with a professional profile" do
    user = users(:one)
    firm = Firm.create!(name: "Synthetic office", verification_status: "verified", verified_at: Time.current)
    user.memberships.create!(firm: firm, role: "owner")
    user.create_lawyer_profile!(verification_status: "verified", verified_at: Time.current,
      professional_email: user.email_address, bar_association: "OVB", bar_number: "ADMIN-SEPARATION")
    user.update!(email_verified_at: Time.current)
    assert_predicate user, :marketplace_verified?

    user.update!(system_role: "admin")
    assert_not_predicate user, :marketplace_verified?
  end

  test "downcases and strips email_address" do
    user = User.new(email_address: " DOWNCASED@EXAMPLE.COM ")
    assert_equal("downcased@example.com", user.email_address)
  end

  test "email change clears verification even with a stale unverified object" do
    user = users(:one)
    user.update!(email_verified_at: nil)
    stale_user = User.find(user.id)
    user.update!(email_verified_at: Time.current)

    stale_user.update!(email_address: "new@example.test")

    assert_nil user.reload.email_verified_at
  end

  test "email tokens expire and are bound to the current normalized address" do
    user = users(:one)
    token = user.email_verification_token
    assert_equal user, User.find_by_email_verification_token!(token)
    user.update!(email_address: "replacement@example.test")
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { User.find_by_email_verification_token!(token) }

    fresh_token = user.email_verification_token
    travel 49.hours do
      assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) { User.find_by_email_verification_token!(fresh_token) }
    end
  end

  test "password minimum applies to new passwords without blocking other updates" do
    user = users(:one)
    assert user.update(first_name: "Changed")
    assert_not user.update(password: "short", password_confirmation: "short")
    assert user.errors.of_kind?(:password, :too_short)
  end
end
