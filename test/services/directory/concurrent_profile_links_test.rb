require "test_helper"

class Directory::ConcurrentProfileLinksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "simultaneous alternative-email signups through old and direct links persist exactly one account" do
    old_id, new_id = SecureRandom.uuid, SecureRandom.uuid
    base = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/"
    emails = Array.new(2) { "registration-#{SecureRandom.hex(8)}@example.test" }
    ready, launch = Queue.new, Queue.new
    threads = emails.each_with_index.map do |email, index|
      Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          ready << true
          launch.pop
          ApplicationRecord.transaction do
            user = User.create!(first_name: "Concurrent", last_name: "Lawyer", email_address: email, password: "test-password-12345")
            profile = LawyerProfile.create!(user:, bar_association: "OVB", bar_number: SecureRandom.uuid,
              directory_profile_url: base + new_id)
            Directory::ProfileLinks.register_signup!(profile:, identity: {
              "name" => user.full_name, "email_address" => "office@example.test",
              "original_profile_url" => base + [ old_id, new_id ].fetch(index), "profile_url" => base + new_id })
          end
          :created
        rescue Directory::ProfileLinks::Conflict
          :conflict
        end
      end
    end
    2.times { ready.pop }
    2.times { launch << true }
    assert_equal %i[conflict created], threads.map(&:value).sort
    surviving = User.where(email_address: emails).sole
    assert_equal surviving.lawyer_profile.id, DirectoryProfileLink.find_by!(directory_profile_id: new_id).lawyer_profile_id
    assert_equal 1, DirectoryProfileLink.where(directory_profile_id: [ old_id, new_id ]).distinct.count(:lawyer_profile_id)
  ensure
    User.where(email_address: emails).find_each do |user|
      user.lawyer_profile&.destroy!
      user.destroy!
    end
  end
end
