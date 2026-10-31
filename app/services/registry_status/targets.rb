module RegistryStatus
  class Targets
    Target = Data.define(:source, :value, :identity_digest, :firm_id, :lawyer_profile_id, :full_name, :expected_email) do
      def digest = RegistryStatusCheck.target_digest(source:, value:, lawyer_profile_id:)
    end

    def self.all
      new.all
    end

    def all
      targets = []
      members = User.where(system_role: "member", erased_at: nil)
      LawyerProfile.where(user_id: members.select(:id)).includes(:user).find_each do |profile|
        url = Directory::AdvocaatBeProfileLookup.canonical_profile_url(profile.directory_profile_url)&.downcase
        next unless url
        name = profile.directory_name.presence || profile.user.full_name
        email = profile.directory_email.presence
        identity = RegistryStatusCheck.digest("directory_identity", [ name, email ].join("\u0000"))
        targets << Target.new(source: "directory", value: url, identity_digest: identity,
          firm_id: nil, lawyer_profile_id: profile.id, full_name: name, expected_email: email)
      end
      targets
    end
  end
end
