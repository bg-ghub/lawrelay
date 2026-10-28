module Directory
  class ConfirmationToken
    PURPOSE = "lawrelay/directory-confirmation/v1"

    def self.generate(profile)
      encryptor.encrypt_and_sign(
        { "profile_id" => profile.id, "user_id" => profile.user_id, "directory_profile_id" => profile.directory_profile_id,
          "identity_digest" => profile.directory_identity_digest, "directory_email" => profile.directory_email,
          "directory_name" => profile.directory_name, "directory_profile_url" => profile.directory_profile_url,
          "login_email" => profile.user.email_address, "full_name" => profile.user.full_name },
        expires_in: 48.hours
      )
    end

    def self.find_profile!(token)
      payload = encryptor.decrypt_and_verify(token)
      profile = LawyerProfile.find(payload.fetch("profile_id"))
      user = profile.user
      raise ActiveSupport::MessageVerifier::InvalidSignature unless user.active? && profile.user_id == payload.fetch("user_id") &&
        profile.directory_profile_id == payload.fetch("directory_profile_id") &&
        ActiveSupport::SecurityUtils.secure_compare(profile.directory_identity_digest.to_s, payload.fetch("identity_digest").to_s) &&
        ActiveSupport::SecurityUtils.secure_compare(profile.directory_email.to_s, payload.fetch("directory_email").to_s) &&
        ActiveSupport::SecurityUtils.secure_compare(profile.directory_name.to_s, payload.fetch("directory_name").to_s) &&
        ActiveSupport::SecurityUtils.secure_compare(profile.directory_profile_url.to_s, payload.fetch("directory_profile_url").to_s) &&
        ActiveSupport::SecurityUtils.secure_compare(user.email_address.to_s, payload.fetch("login_email").to_s) &&
        ActiveSupport::SecurityUtils.secure_compare(user.full_name.to_s, payload.fetch("full_name").to_s) &&
        AdvocaatBeProfileLookup.names_match?(profile.directory_name, user.full_name)

      profile
    rescue KeyError, ActiveSupport::MessageEncryptor::InvalidMessage
      raise ActiveSupport::MessageVerifier::InvalidSignature
    end

    def self.encryptor
      @encryptor ||= ActiveSupport::MessageEncryptor.new(
        Rails.application.key_generator.generate_key(PURPOSE, ActiveSupport::MessageEncryptor.key_len), cipher: "aes-256-gcm"
      )
    end
  end
end
