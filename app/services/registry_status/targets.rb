module RegistryStatus
  class Targets
    Target = Data.define(:source, :value, :identity_digest, :firm_id, :lawyer_profile_id, :full_name, :expected_email) do
      def digest = RegistryStatusCheck.target_digest(source:, value:, lawyer_profile_id:)
    end

    def self.all
      new.all
    end

    def all
      seen = {}
      targets = []
      members = User.where(system_role: "member", erased_at: nil)
      Firm.joins(:memberships).where(memberships: { user_id: members.select(:id) }).distinct.find_each do |firm|
        number = Firm.normalize_enterprise_number(firm.enterprise_number)
        next unless Firm.valid_enterprise_number?(number)
        next if seen[[ "kbo", number ]]

        seen[[ "kbo", number ]] = true
        targets << Target.new(source: "kbo", value: number, identity_digest: RegistryStatusCheck.digest("kbo", number),
          firm_id: firm.id, lawyer_profile_id: nil, full_name: nil, expected_email: nil)
      end
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
