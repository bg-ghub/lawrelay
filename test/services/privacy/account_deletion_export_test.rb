require "test_helper"
require_relative "../../support/marketplace_test_factory"

class AccountDeletionExportTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  self.fixture_table_names = []

  test "deletion dates and lifecycle are exported only for the requester without internal digests" do
    own = create_marketplace_account(prefix: "grace-export-own")
    other = create_marketplace_account(prefix: "grace-export-other")
    deletion = Accounts::Deletion.schedule!(user: own.user, current_session: own.user.sessions.create!, password: "password1234")
    other_deletion = Accounts::Deletion.schedule!(user: other.user, current_session: other.user.sessions.create!, password: "password1234")
    admin = create_marketplace_account(prefix: "grace-export-admin", system_role: "admin").user
    request = own.user.privacy_requests.create!(kind: "access_export", status: "in_review", handled_by_user: admin, details: "Synthetic export.")
    package = Privacy::AccountExport.new(request:, actor: admin).send(:package)

    assert package[:account].fetch("deletion_requested_at")
    assert package[:account].fetch("deletion_scheduled_at")
    assert_equal [ deletion.id ], package[:account_deletion_requests].pluck("id")
    assert_not_includes package[:account_deletion_requests].pluck("id"), other_deletion.id
    assert_not_includes package.to_json, deletion.email_identity_digest
    assert_not_includes package.to_json, other.user.email_address
    assert_not_includes package.to_json, "finalization_claimed_at"
  end
end
