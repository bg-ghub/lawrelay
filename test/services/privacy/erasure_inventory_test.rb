require "test_helper"
require "tmpdir"
require "json"
require_relative "../../support/marketplace_test_factory"

class PrivacyErasureInventoryTest < ActiveSupport::TestCase
  include MarketplaceTestFactory

  test "inventory records review obligations without deleting or deciding a hold" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    member = create_marketplace_account(prefix: "erasuremember")
    other = create_marketplace_account(prefix: "erasureother")
    other.user.memberships.create!(firm: member.firm)
    admin = User.create!(first_name: "Privacy", last_name: "Operator", email_address: "privacy-inventory-admin@example.test",
      password: "safe-password-123", system_role: "admin", admin_mfa_enabled_at: Time.current,
      admin_mfa_secret_ciphertext: "test-ciphertext")
    request = member.user.privacy_requests.create!(kind: "deletion", status: "in_review", handled_by_user: admin, details: "Delete my account")
    assignment = create_assignment_for(member)
    create_proposal_for(assignment, other)

    Dir.mktmpdir("lawrelay-erasure-inventory-") do |directory|
      File.chmod(0o700, directory)
      output = File.join(directory, "inventory.json")
      assert_no_difference([ "User.count", "Assignment.count", "Proposal.count", "Membership.count", "PrivacyRequest.count" ]) do
        assert_difference("AuditEvent.where(action: 'privacy.erasure_inventory_prepared').count", 1) do
          Privacy::ErasureInventory.new(request:, actor: admin).call(output_path: output)
        end
      end
      data = JSON.parse(File.read(output))
      assert_equal true, data.fetch("dry_run")
      assert_equal false, data.fetch("deletion_performed")
      assert_equal false, data.fetch("automatic_deletion_allowed")
      assert_equal "not_assessed", data.fetch("hold_decision")
      assert_equal 1, data.dig("references", "shared_firms")
      assert_equal 1, data.dig("references", "created_assignments")
      assert_equal "in_review", request.reload.status
      assert_nil request.resolved_at
      assert_equal 0o600, File.stat(output).mode & 0o777
      refute_includes File.read(output), other.user.email_address
    end
  end
end
