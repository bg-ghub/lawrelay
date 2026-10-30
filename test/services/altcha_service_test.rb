require "test_helper"

class AltchaServiceTest < ActiveSupport::TestCase
  test "a challenge can be solved once with its matching browser nonce" do
    nonce = SecureRandom.hex(16)
    challenge = AltchaService.generate_challenge(nonce:)
    solution = (0..AltchaService::MAX_NUMBER).find do |number|
      OpenSSL::Digest::SHA256.hexdigest("#{challenge[:salt]}#{number}") == challenge[:challenge]
    end
    assert solution

    payload = Base64.strict_encode64({ algorithm: "SHA-256", challenge: challenge[:challenge], salt: challenge[:salt], signature: challenge[:signature], number: solution }.to_json)
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    assert AltchaService.verify_solution(payload, nonce:)
    refute AltchaService.verify_solution(payload, nonce:), "the proof must not survive a copied browser session"
    refute AltchaService.verify_solution(payload, nonce: "another-browser")
  ensure
    Rails.cache = previous_cache
  end

  test "rejects expired or oversized proofs" do
    refute AltchaService.verify_solution("A" * (AltchaService::MAX_PAYLOAD_BYTES + 1), nonce: SecureRandom.hex(16))
    challenge = AltchaService.generate_challenge(nonce: SecureRandom.hex(16), now: 20.minutes.ago)
    payload = Base64.strict_encode64({ algorithm: "SHA-256", challenge: challenge[:challenge], salt: challenge[:salt], signature: challenge[:signature], number: 0 }.to_json)
    refute AltchaService.verify_solution(payload, nonce: challenge[:salt].split("?").first)
  end
end
