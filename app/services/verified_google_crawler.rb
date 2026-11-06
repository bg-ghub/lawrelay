require "digest"
require "ipaddr"
require "resolv"
require "timeout"

class VerifiedGoogleCrawler
  USER_AGENT = /\b(?:Googlebot|Google-InspectionTool)\b/i
  HOSTNAME = /\A(?:crawl-[a-z0-9-]+\.googlebot\.com|geo-crawl-[a-z0-9-]+\.geo\.googlebot\.com|google-proxy-[a-z0-9-]+\.google\.com)\z/
  DNS_TIMEOUT = 2
  SUCCESS_TTL = 24.hours
  FAILURE_TTL = 5.minutes

  class << self
    def call(ip:, user_agent:, cache: Rails.cache, resolver: Resolv::DNS)
      return false unless USER_AGENT.match?(user_agent.to_s)

      address = normalized_address(ip)
      return false unless address

      key = "verified-google-crawler:v1:#{Digest::SHA256.hexdigest(address)}"
      cached = cache.read(key)
      return cached if cached == true || cached == false

      verified = lookup(address, resolver:)
      cache.write(key, verified, expires_in: verified ? SUCCESS_TTL : FAILURE_TTL)
      verified
    rescue StandardError => error
      Rails.logger.warn("Google crawler verification unavailable: #{error.class}")
      false
    end

    private

    def normalized_address(value)
      text = value.to_s.strip
      return if text.include?("/") || text.include?("%")

      address = IPAddr.new(text).native
      return if address.loopback? || address.private? || address.link_local?

      address.to_s
    rescue IPAddr::Error
      nil
    end

    def lookup(address, resolver:)
      Timeout.timeout(DNS_TIMEOUT, Resolv::ResolvTimeout) do
        resolver.open do |dns|
          dns.timeouts = [ 0.5, 0.5 ]
          dns.getnames(address).first(5).any? do |name|
            hostname = name.to_s.downcase.delete_suffix(".")
            next false unless HOSTNAME.match?(hostname)

            dns.getaddresses("#{hostname}.").any? { |forward| normalized_address(forward) == address }
          end
        end
      end
    rescue Resolv::ResolvError, Resolv::ResolvTimeout, IOError, SystemCallError
      false
    end
  end
end
