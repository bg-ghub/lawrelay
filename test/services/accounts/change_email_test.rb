require "test_helper"
require_relative "../../support/marketplace_test_factory"

class Accounts::ChangeEmailTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "email-change")
    @profile = @account.profile
    @profile.update!(
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a",
      directory_profile_id: "63fee2a5-637a-4839-a5a6-c833482f1e3a", directory_name: @account.user.full_name,
      directory_email: @account.user.email_address, directory_checked_at: Time.current,
      directory_email_verified_at: Time.current, directory_identity_digest: "old-proof"
    )
    @current_session = @account.user.sessions.create!
    @other_session = @account.user.sessions.create!
  end

  test "changes the email, discards old proof, and retains only the current session" do
    result = Accounts::ChangeEmail.call(
      user: @account.user, current_session: @current_session,
      password: "password1234", email_address: " NEW@EXAMPLE.TEST "
    )

    assert_predicate result, :success?
    assert_equal "new@example.test", @account.user.reload.email_address
    assert_nil @account.user.email_verified_at
    assert_equal [ @current_session.id ], @account.user.sessions.pluck(:id)
    @profile.reload
    assert_equal "pending", @profile.verification_status
    assert_nil @profile.directory_profile_id
    assert_nil @profile.directory_email
    assert_nil @profile.directory_identity_digest
    assert_equal "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a", @profile.directory_profile_url
    assert_equal @account.firm, @account.user.primary_firm
  end

  test "wrong password does not mutate identity, evidence, or sessions" do
    original_email = @account.user.email_address
    result = Accounts::ChangeEmail.call(
      user: @account.user, current_session: @current_session,
      password: "wrong", email_address: "new@example.test"
    )

    assert_not_predicate result, :success?
    assert_equal original_email, @account.user.reload.email_address
    assert_equal "63fee2a5-637a-4839-a5a6-c833482f1e3a", @profile.reload.directory_profile_id
    assert_equal [ @current_session.id, @other_session.id ].sort, @account.user.sessions.pluck(:id).sort
  end

  test "unchanged normalized email does not revoke verification or sessions" do
    result = Accounts::ChangeEmail.call(
      user: @account.user, current_session: @current_session,
      password: "password1234", email_address: " #{@account.user.email_address.upcase} "
    )

    assert_not_predicate result, :success?
    assert_predicate @account.user.reload, :email_verified?
    assert_equal "63fee2a5-637a-4839-a5a6-c833482f1e3a", @profile.reload.directory_profile_id
    assert_equal [ @current_session.id, @other_session.id ].sort, @account.user.sessions.pluck(:id).sort
  end

  test "a session from another account cannot authorize a change" do
    other_account = create_marketplace_account(prefix: "other-session")
    foreign_session = other_account.user.sessions.create!
    original_email = @account.user.email_address

    result = Accounts::ChangeEmail.call(
      user: @account.user, current_session: foreign_session,
      password: "password1234", email_address: "new@example.test"
    )

    assert_not_predicate result, :success?
    assert_equal original_email, @account.user.reload.email_address
    assert_predicate @account.user, :email_verified?
    assert_equal "63fee2a5-637a-4839-a5a6-c833482f1e3a", @profile.reload.directory_profile_id
    assert_equal [ @current_session.id, @other_session.id ].sort, @account.user.sessions.pluck(:id).sort
  end
end
