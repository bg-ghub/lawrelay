require "test_helper"
require "rake"
require "tmpdir"
require "json"
require_relative "../../support/marketplace_test_factory"

Rails.application.load_tasks unless Rake::Task.task_defined?("privacy:export")

class PrivacyTasksTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include MarketplaceTestFactory

  setup do
    member = create_marketplace_account(prefix: "privacytask")
    @admin = User.create!(first_name: "Privacy", last_name: "Operator", email_address: "privacy-task-admin@example.test",
      password: "safe-password-123", system_role: "admin", admin_mfa_enabled_at: Time.current,
      admin_mfa_secret_ciphertext: "test-secret")
    @request = member.user.privacy_requests.create!(kind: "access_export", status: "in_review",
      handled_by_user: @admin, details: "Please export my account")
    @original_output = ENV["OUTPUT"]
  end

  teardown do
    ENV["OUTPUT"] = @original_output
  end

  test "task prepares an audited package without printing or sending the account data" do
    skip "POSIX file permissions are required" if Gem.win_platform?
    Dir.mktmpdir("lawrelay-privacy-task-") do |directory|
      File.chmod(0o700, directory)
      ENV["OUTPUT"] = File.join(directory, "review.json")
      assert_no_enqueued_jobs do
        output, errors = capture_io { invoke("privacy:export", @request.id, @admin.id) }
        assert_includes output, "Private review package saved."
        refute_includes output, @request.user.email_address
        refute_includes output, @request.details
        assert_empty errors
      end
      assert_equal @request.user_id, JSON.parse(File.read(ENV.fetch("OUTPUT"))).dig("account", "id")
      assert_equal "in_review", @request.reload.status
    end
  end

  test "malformed identifiers, missing output and wrong request kind fail closed" do
    ENV.delete("OUTPUT")
    assert_no_difference("AuditEvent.count") do
      capture_io do
        assert_raises(SystemExit) { invoke("privacy:export", "1 OR 1=1", @admin.id) }
        assert_raises(SystemExit) { invoke("privacy:export", @request.id, @admin.id) }
        ENV["OUTPUT"] = "/not-created/review.json"
        assert_raises(SystemExit) { invoke("privacy:erasure_inventory", @request.id, @admin.id) }
      end
    end
  end

  private

  def invoke(name, request_id, actor_id)
    task = Rake::Task[name]
    task.reenable
    task.invoke(request_id.to_s, actor_id.to_s)
  end
end
