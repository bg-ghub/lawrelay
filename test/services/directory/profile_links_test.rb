require "test_helper"

class Directory::ProfileLinksTest < ActiveSupport::TestCase
  setup do
    @old, @new = SecureRandom.uuid, SecureRandom.uuid
    @owner = profile_for(users(:one))
    @applicant = profile_for(users(:two))
  end

  test "signed registration owns each observed URL once in either order" do
    Directory::ProfileLinks.register_signup!(profile: @owner, identity: identity(@old, @new))
    Directory::ProfileLinks.register_signup!(profile: @owner, identity: identity(@new, @new))
    assert_equal [ @old, @new ].sort, DirectoryProfileLink.where(lawyer_profile: @owner).pluck(:directory_profile_id).sort
    assert_raises Directory::ProfileLinks::Conflict do
      Directory::ProfileLinks.register_signup!(profile: @applicant, identity: identity(@new, @new))
    end
    assert Directory::ProfileLinks.claimed_by_other?(profile: @applicant, profile_ids: [ @old ])
  end

  test "a new URL claimed first blocks a signup through an earlier URL without creating a partial alias" do
    Directory::ProfileLinks.register_signup!(profile: @owner, identity: identity(@new, @new))
    assert_raises Directory::ProfileLinks::Conflict do
      Directory::ProfileLinks.register_signup!(profile: @applicant, identity: identity(@old, @new))
    end
    assert_equal [ @new ], DirectoryProfileLink.pluck(:directory_profile_id)
  end

  test "two direct previews issued before and after a move cannot create separate unverified accounts" do
    Directory::ProfileLinks.register_signup!(profile: @owner, identity: identity(@old, @old))
    refute @owner.reload.directory_matched?
    assert_nil @owner.directory_email_verified_at
    assert_raises Directory::ProfileLinks::Conflict do
      Directory::ProfileLinks.register_signup!(profile: @applicant, identity: identity(@new, @new))
    end
    assert_equal [ @old ], DirectoryProfileLink.pluck(:directory_profile_id)
  end

  test "new direct URL for a legacy identity is blocked without assigning or changing its former account" do
    @owner.update!(directory_profile_url: url(@old), directory_profile_id: @old,
      directory_name: "Original Lawyer", directory_email: "directory@example.test")
    assert_no_difference("DirectoryProfileLink.count") do
      assert_raises Directory::ProfileLinks::Conflict do
        Directory::ProfileLinks.register_signup!(profile: @applicant, identity: identity(@new, @new))
      end
    end
    assert_equal @old, @owner.reload.directory_profile_id
    assert_equal "pending", @owner.verification_status
  end

  test "existing pending URL-only account and historical conflicting evidence cannot be assigned to someone else" do
    @owner.update!(directory_profile_url: url(@old))
    assert_raises Directory::ProfileLinks::Conflict do
      Directory::ProfileLinks.register_signup!(profile: @applicant, identity: identity(@old, @new))
    end
    assert_empty DirectoryProfileLink.all
  end

  test "the database enforces unique aliases and releases them on profile erasure" do
    Directory::ProfileLinks.register!(profile: @owner, profile_ids: [ @old, @new ])
    assert_raises ActiveRecord::RecordNotUnique do
      DirectoryProfileLink.transaction(requires_new: true) do
        DirectoryProfileLink.insert_all!([ { lawyer_profile_id: @applicant.id, directory_profile_id: @new.upcase } ])
      end
    end
    @owner.destroy!
    assert_empty DirectoryProfileLink.all
    Directory::ProfileLinks.register!(profile: @applicant, profile_ids: [ @new ])
    assert_equal @applicant.id, DirectoryProfileLink.find_by!(directory_profile_id: @new).lawyer_profile_id
  end

  private

  def profile_for(user)
    LawyerProfile.create!(user:, bar_association: "OVB", bar_number: "TEST-#{SecureRandom.hex(5)}")
  end

  def url(id) = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{id}"

  def identity(original, final)
    { "name" => "Original Lawyer", "email_address" => "directory@example.test",
      "original_profile_url" => url(original), "profile_url" => url(final) }
  end
end
