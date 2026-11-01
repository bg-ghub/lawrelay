require "digest"

module Travel
  class Estimate
    Result = Data.define(:status, :distance_meters, :duration_seconds) do
      def ready? = status == :ready
    end
    SUCCESS_TTL = 7.days
    FAILURE_TTL = 5.minutes
    CLAIM_TTL = 2.minutes

    def self.call(proposal:, index: AddressIndex.new, router: Router.new, cache: Rails.cache)
      new(proposal:, index:, router:, cache:).call
    end

    def self.compute(proposal:, index: AddressIndex.new, router: Router.new, cache: Rails.cache)
      new(proposal:, index:, router:, cache:).compute
    end

    def initialize(proposal:, index:, router:, cache:)
      @proposal = proposal
      @index = index
      @router = router
      @cache = cache
    end

    def call
      return result(:not_applicable) unless applicable?
      return result(:unavailable) unless available?
      cached = @cache.read(key)
      return result_from_cache(cached) if cached

      if @cache.write(claim_key, true, unless_exist: true, expires_in: CLAIM_TTL)
        TravelEstimateJob.perform_later(@proposal.id)
      end
      result(:pending)
    rescue ActiveJob::EnqueueError, ActiveRecord::ActiveRecordError
      @cache.delete(claim_key) if available?
      result(:unavailable)
    end

    def compute
      return result(:not_applicable) unless applicable?
      return result(:unavailable) unless available?
      fingerprint = key
      origin = @index.address(@proposal.user.lawyer_profile.directory_professional_address)
      assignment = @proposal.assignment
      destination = @index.court(name: assignment.court, city: assignment.city)
      route = @router.route(origin:, destination:) if origin && destination
      calculated = route ? result(:ready, distance_meters: route.distance_meters, duration_seconds: route.duration_seconds) : result(:unavailable)
      @proposal.reload
      # Never publish an estimate for an identity or address changed mid-lookup.
      return result(:unavailable) unless applicable? && available? && fingerprint == key

      @cache.write(fingerprint, calculated.to_h, expires_in: route ? SUCCESS_TTL : FAILURE_TTL)
      @cache.delete(claim_key)
      calculated
    end

    private

    def applicable?
      @proposal.persisted? && @proposal.rate_kind == "hourly" && @proposal.assignment.court_replacement? &&
        @proposal.user&.marketplace_verified? && @proposal.user.lawyer_profile&.directory_matched?
    end

    def available?
      @proposal.user.lawyer_profile.directory_professional_address.present? &&
        @proposal.assignment.court.present? && @proposal.assignment.city.present? && @index.available? && @router.available?
    end

    def key
      profile = @proposal.user.lawyer_profile
      assignment = @proposal.assignment
      digest = Digest::SHA256.hexdigest([ @proposal.id, profile.directory_profile_id, profile.directory_professional_address,
        assignment.court, assignment.city, @index.version ].join("\0"))
      "travel-estimate:v1:#{digest}"
    end

    def claim_key
      "#{key}:queued"
    end

    def result(status, distance_meters: nil, duration_seconds: nil)
      Result.new(status:, distance_meters:, duration_seconds:)
    end

    def result_from_cache(cached)
      return result(:unavailable) unless cached.is_a?(Hash)

      values = cached.symbolize_keys.slice(:status, :distance_meters, :duration_seconds)
      values[:status] = values[:status].to_sym if values[:status].respond_to?(:to_sym)
      return result(:unavailable) unless values[:status] == :ready
      return result(:unavailable) unless values[:distance_meters].is_a?(Integer) && values[:distance_meters].between?(0, 1_000_000) &&
        values[:duration_seconds].is_a?(Integer) && values[:duration_seconds].between?(0, 86_400)

      Result.new(**values)
    end
  end
end
