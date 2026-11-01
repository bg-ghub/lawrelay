require "test_helper"
require_relative "../../support/marketplace_test_factory"

class DirectoryProfileSyncTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  PROFILE_URL = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/63fee2a5-637a-4839-a5a6-c833482f1e3a"

  setup do
    @account = linked_account("profilesync")
  end

  test "refresh persists only importable fields and audits their names without altering verification or account identity" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes.except("spoken_languages", "practice_areas", "updated_at")
    calls = []
    importer = lambda do |**arguments|
      calls << arguments
      imported(spoken_languages: %w[NL FR], practice_areas: [ "Familierecht" ],
        professional_email: "forged@example.test", verification_status: "pending", directory_name: "Forged")
    end

    assert_no_enqueued_jobs do
      assert_difference "AuditEvent.count", 1 do
        result = Directory::ProfileSync.call(user: @account.user, import: importer, actor: @account.user)
        assert result.success?
        assert_equal :updated, result.status
        assert_equal %w[spoken_languages practice_areas], result.changed_fields
      end
    end

    assert_equal [ { profile_url: PROFILE_URL, full_name: @account.user.full_name } ], calls
    assert_equal %w[NL FR], @account.profile.reload.spoken_languages
    assert_equal [ "Familierecht" ], @account.profile.practice_areas
    assert_equal original_user, @account.user.reload.attributes
    assert_equal original_profile, @account.profile.attributes.except("spoken_languages", "practice_areas", "updated_at")
    event = AuditEvent.order(:id).last
    assert_equal @account.profile, event.auditable
    assert_equal @account.user, event.actor_user
    assert_equal "profile.directory_synced", event.action
    assert_equal({ "changed_fields" => %w[spoken_languages practice_areas], "source" => "advocaat.be" }, event.metadata)
  end

  test "an identical daily refresh makes no writes or extra audit event" do
    importer = ->(**) { imported(spoken_languages: %w[NL FR]) }
    Directory::ProfileSync.call(user: @account.user, import: importer)
    original_profile = @account.profile.reload.attributes

    assert_no_difference "AuditEvent.count" do
      result = Directory::ProfileSync.call(user: @account.user, import: importer)
      assert result.success?
      assert_equal :unchanged, result.status
      assert_empty result.changed_fields
    end

    assert_equal original_profile, @account.profile.reload.attributes
    assert_nil AuditEvent.where(action: "profile.directory_synced").order(:id).last.actor_user
  end

  test "missing source fields preserve stored values and never infer court or availability" do
    @account.profile.update!(practice_areas: [ "Existing domain" ], court_preferences: [ "Existing court" ], availability_note: "Existing note")
    importer = ->(**) { imported(spoken_languages: [ "DE" ]) }

    Directory::ProfileSync.call(user: @account.user, import: importer)

    assert_equal [ "DE" ], @account.profile.reload.spoken_languages
    assert_equal [ "Existing domain" ], @account.profile.practice_areas
    assert_equal [ "Existing court" ], @account.profile.court_preferences
    assert_equal "Existing note", @account.profile.availability_note
  end

  test "unavailable mismatched empty and unlinked sources leave all stored records unchanged" do
    original_user = @account.user.attributes
    original_profile = @account.profile.attributes
    %i[unavailable missing_profile identity_mismatch empty].each do |status|
      importer = ->(**) { Directory::ProfileImport::Result.new(status:, profile_attributes: {}) }
      assert_no_difference "AuditEvent.count" do
        result = Directory::ProfileSync.call(user: @account.user, import: importer)
        assert_equal status, result.status
        assert_not result.success?
      end
      assert_equal original_user, @account.user.reload.attributes
      assert_equal original_profile, @account.profile.reload.attributes
    end
  end

  test "invalid imported arrays cannot cause partial updates or audits" do
    original = @account.profile.attributes
    importer = ->(**) { imported(spoken_languages: %w[NL FR], practice_areas: [ "X" * 101 ]) }

    assert_no_difference "AuditEvent.count" do
      result = Directory::ProfileSync.call(user: @account.user, import: importer)
      assert_equal :invalid_data, result.status
      assert_empty result.changed_fields
    end

    assert_equal original, @account.profile.reload.attributes
  end

  test "a successful provider response cannot assign unsupported profile attributes" do
    original = @account.profile.attributes
    importer = ->(**) { imported(directory_name: "Forged name", directory_email: "forged@example.test", bar_admission_year: 2000) }

    assert_no_difference "AuditEvent.count" do
      result = Directory::ProfileSync.call(user: @account.user, import: importer)
      assert_equal :empty, result.status
    end

    assert_equal original, @account.profile.reload.attributes
  end

  test "suspended erased administrator rejected unlinked and mismatched accounts never fetch" do
    changes = [
      ->(account) { account.user.update_columns(suspended_at: Time.current) },
      ->(account) { account.user.update_columns(erased_at: Time.current) },
      ->(account) { account.user.update_columns(system_role: "admin") },
      ->(account) { account.profile.update_columns(verification_status: "rejected") },
      ->(account) { account.profile.update_columns(verification_status: "suspended") },
      ->(account) { account.profile.update_columns(directory_profile_id: nil) },
      ->(account) { account.profile.update_columns(directory_profile_url: "https://evil.example/profile") },
      ->(account) { account.profile.update_columns(directory_name: "Different identity") }
    ]
    importer = ->(**) { raise "Ineligible profile reached the network" }
    changes.each_with_index do |change, index|
      account = linked_account("ineligiblesync#{index}")
      change.call(account)
      result = Directory::ProfileSync.call(user: account.user, import: importer)
      assert_equal :ineligible, result.status
    end
  end

  test "identity and eligibility changes during fetch discard the result" do
    changes = [
      ->(account) { account.user.update_columns(first_name: "Changed") },
      ->(account) { account.user.update_columns(email_address: "changed@example.test") },
      ->(account) { account.user.update_columns(system_role: "admin") },
      ->(account) { account.user.update_columns(suspended_at: Time.current) },
      ->(account) { account.user.update_columns(erased_at: Time.current) },
      ->(account) { account.profile.update_columns(directory_profile_url: PROFILE_URL.sub("63fee2a5", "73fee2a5")) },
      ->(account) { account.profile.update_columns(directory_email: "changed-directory@example.test") },
      ->(account) { account.profile.update_columns(verification_status: "suspended") }
    ]
    changes.each_with_index do |change, index|
      account = linked_account("stalesync#{index}")
      original_preferences = account.profile.attributes.slice("spoken_languages", "practice_areas")
      importer = lambda do |**|
        change.call(account)
        imported(spoken_languages: [ "FR" ], practice_areas: [ "New domain" ])
      end
      assert_no_difference "AuditEvent.count" do
        result = Directory::ProfileSync.call(user: account.user, import: importer)
        assert_equal :stale, result.status
      end
      assert_equal original_preferences, account.profile.reload.attributes.slice("spoken_languages", "practice_areas")
    end
  end

  test "erased or removed profiles during fetch are not recreated" do
    importer = lambda do |**|
      @account.profile.destroy!
      imported(spoken_languages: [ "FR" ])
    end
    assert_no_difference "AuditEvent.count" do
      assert_difference "LawyerProfile.count", -1 do
        result = Directory::ProfileSync.call(user: @account.user, import: importer)
        assert_equal :stale, result.status
      end
    end
    assert_nil @account.user.reload.lawyer_profile
  end

  test "a slower refresh cannot overwrite fields updated by another refresh during its request" do
    importer = lambda do |**|
      @account.profile.update!(spoken_languages: %w[NL FR])
      imported(spoken_languages: [ "NL" ])
    end

    assert_no_difference "AuditEvent.count" do
      result = Directory::ProfileSync.call(user: @account.user, import: importer)
      assert_equal :stale, result.status
    end
    assert_equal %w[NL FR], @account.profile.reload.spoken_languages
  end

  private

  def linked_account(prefix)
    account = create_marketplace_account(prefix:)
    account.profile.update!(directory_profile_url: PROFILE_URL,
      directory_profile_id: "#{prefix}-#{SecureRandom.hex(4)}", directory_name: account.user.full_name,
      directory_email: account.user.email_address, directory_checked_at: Time.current)
    account
  end

  def imported(**attributes)
    Directory::ProfileImport::Result.new(status: :ok, profile_attributes: attributes)
  end
end
