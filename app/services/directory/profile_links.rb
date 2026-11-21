module Directory
  class ProfileLinks
    class Conflict < StandardError; end

    def self.register_signup!(profile:, identity:)
      ids = [ identity["original_profile_url"] || identity.fetch("profile_url"), identity.fetch("profile_url") ].map do |url|
        id_from_url(url) || raise(ArgumentError, "Invalid official profile link")
      end
      ApplicationRecord.transaction do
        # A direct visit to the new URL cannot reveal its predecessor. Refuse
        # another signup when the directory still lists the same name and email.
        candidates = LawyerProfile.where.not(id: profile.id).where(directory_email: identity.fetch("email_address"))
        if candidates.pluck(:directory_name).any? { |name| AdvocaatBeProfileLookup.names_match?(name, identity.fetch("name")) }
          raise Conflict
        end
        register!(profile:, profile_ids: ids)
        # Retain the server-observed listing identity even if the applicant
        # chose a different login email. Verification still requires a fresh
        # lookup, its timestamp and independent email confirmation or review.
        unless profile.directory_matched?
          profile.update!(directory_name: identity.fetch("name"), directory_email: identity.fetch("email_address"))
        end
      end
    end

    def self.register!(profile:, profile_ids:)
      ids = normalize_ids(profile_ids)
      raise ArgumentError, "Expected a persisted profile and directory identity" unless profile.persisted? && ids.any?

      ApplicationRecord.transaction(requires_new: true) do
        raise Conflict if stored_profiles_with(ids).where.not(id: profile.id).exists?
        ids.each do |id|
          link = DirectoryProfileLink.create_or_find_by!(directory_profile_id: id) { |record| record.lawyer_profile = profile }
          raise Conflict unless link.lawyer_profile_id == profile.id
        end
      end
    end

    def self.claimed_by_other?(profile:, profile_ids:)
      # Older local identifiers can still participate in the existing exact
      # ownership comparison. Only official UUIDs may be inserted as links.
      ids = profile_ids.compact.map { |id| id.to_s.downcase }.uniq
      return false if ids.empty?

      DirectoryProfileLink.where(directory_profile_id: ids).where.not(lawyer_profile_id: profile.id).exists? ||
        stored_profiles_with(ids).where.not(id: profile.id)
          .where("directory_email_verified_at IS NOT NULL OR email_review_status = ? OR manual_activation_approved_at IS NOT NULL", "approved").exists?
    end

    def self.id_from_url(url)
      canonical = AdvocaatBeProfileLookup.canonical_profile_url(url)
      canonical&.split("/")&.last&.downcase
    end

    def self.normalize_ids(profile_ids)
      ids = profile_ids.compact.map { |id| id.to_s.downcase }.uniq.sort
      raise ArgumentError, "Invalid directory identifier" unless ids.all? { |id| /\A#{AdvocaatBeProfileLookup::UUID}\z/.match?(id) }
      ids
    end
    private_class_method :normalize_ids

    def self.stored_profiles_with(ids)
      urls = ids.flat_map do |id|
        AdvocaatBeProfileLookup::HOSTS.flat_map do |host|
          [ "https://#{host}/nl/zoek-een-advocaat/advocaat/#{id}", "https://#{host}:443/nl/zoek-een-advocaat/advocaat/#{id}" ]
        end
      end
      LawyerProfile.where("lower(directory_profile_id) IN (?) OR lower(directory_profile_url) IN (?)", ids, urls)
    end
    private_class_method :stored_profiles_with
  end
end
