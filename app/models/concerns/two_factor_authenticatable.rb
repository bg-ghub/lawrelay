module TwoFactorAuthenticatable
  extend ActiveSupport::Concern

  class InvalidTwoFactorCode < StandardError; end
  class InvalidTwoFactorPassword < StandardError; end

  def two_factor_enabled?
    two_factor_enabled_at.present?
  end

  def begin_two_factor_setup!(password:)
    with_lock do
      raise InvalidTwoFactorCode if system_admin? || two_factor_enabled?
      raise InvalidTwoFactorPassword unless authenticate(password.to_s)
      next two_factor_pending_secret if two_factor_pending_secret.present?

      secret = ROTP::Base32.random_base32
      update!(two_factor_pending_secret_ciphertext: encrypt_two_factor_secret(secret))
      secret
    end
  end

  def two_factor_pending_secret
    decrypt_two_factor_secret(two_factor_pending_secret_ciphertext)
  end

  def two_factor_provisioning_uri(secret = two_factor_pending_secret)
    return if secret.blank?

    ROTP::TOTP.new(secret, issuer: "LawRelay").provisioning_uri(email_address)
  end

  def enable_two_factor!(code)
    with_lock do
      raise InvalidTwoFactorCode if system_admin? || two_factor_enabled?

      verified_at = verify_two_factor_secret(two_factor_pending_secret, code)
      raise InvalidTwoFactorCode unless verified_at

      codes = Array.new(10) { SecureRandom.hex(10).scan(/.{5}/).join("-") }
      update!(
        two_factor_secret_ciphertext: two_factor_pending_secret_ciphertext,
        two_factor_pending_secret_ciphertext: nil,
        two_factor_enabled_at: Time.current,
        two_factor_last_verified_at: Time.at(verified_at),
        two_factor_recovery_code_digests: codes.map { |value| recovery_code_digest(value) }
      )
      codes
    end
  end

  def verify_two_factor_code!(code: nil, recovery_code: nil)
    with_lock do
      raise InvalidTwoFactorCode unless two_factor_enabled?

      consume_two_factor_challenge!(code:, recovery_code:)
    end
  end

  def disable_two_factor!(password:, code: nil, recovery_code: nil)
    with_lock do
      raise InvalidTwoFactorCode if system_admin? || !two_factor_enabled?
      raise InvalidTwoFactorPassword unless authenticate(password.to_s)

      consume_two_factor_challenge!(code:, recovery_code:)
      update!(
        two_factor_secret_ciphertext: nil,
        two_factor_pending_secret_ciphertext: nil,
        two_factor_enabled_at: nil,
        two_factor_last_verified_at: nil,
        two_factor_recovery_code_digests: []
      )
    end
  end

  def two_factor_recovery_codes_remaining
    two_factor_recovery_code_digests.length
  end

  class_methods do
    def two_factor_encryptor
      @two_factor_encryptor ||= ActiveSupport::MessageEncryptor.new(
        Rails.application.key_generator.generate_key(
          "lawrelay/user-two-factor-secret/v1", ActiveSupport::MessageEncryptor.key_len
        ),
        cipher: "aes-256-gcm"
      )
    end
  end

  private

  def consume_two_factor_challenge!(code:, recovery_code:)
    if recovery_code.present?
      digest = recovery_code_digest(recovery_code)
      matched = digest && two_factor_recovery_code_digests.find do |stored|
        ActiveSupport::SecurityUtils.secure_compare(stored, digest)
      end
      raise InvalidTwoFactorCode unless matched

      update!(two_factor_recovery_code_digests: two_factor_recovery_code_digests - [ matched ])
      Time.current
    else
      verified_at = verify_two_factor_secret(
        decrypt_two_factor_secret(two_factor_secret_ciphertext), code, after: two_factor_last_verified_at
      )
      raise InvalidTwoFactorCode unless verified_at

      update!(two_factor_last_verified_at: Time.at(verified_at))
      Time.at(verified_at)
    end
  end

  def verify_two_factor_secret(secret, code, after: nil)
    value = code.to_s.strip
    return if secret.blank? || !value.match?(/\A[0-9]{6}\z/)

    ROTP::TOTP.new(secret, issuer: "LawRelay").verify(
      value, drift_behind: 30, drift_ahead: 30, after: after&.to_i
    )
  end

  def recovery_code_digest(code)
    value = code.to_s.delete("- \t\r\n").downcase
    return unless value.match?(/\A[0-9a-f]{20}\z/)

    Digest::SHA256.hexdigest(value)
  end

  def encrypt_two_factor_secret(secret)
    self.class.two_factor_encryptor.encrypt_and_sign(secret)
  end

  def decrypt_two_factor_secret(ciphertext)
    return if ciphertext.blank?

    self.class.two_factor_encryptor.decrypt_and_verify(ciphertext)
  rescue ActiveSupport::MessageEncryptor::InvalidMessage
    nil
  end
end
