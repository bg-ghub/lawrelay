require "test_helper"
require_relative "../../support/marketplace_test_factory"

class TravelEstimateTest < ActiveSupport::TestCase
  include MarketplaceTestFactory
  include ActiveJob::TestHelper

  class FakeIndex
    attr_accessor :point
    def initialize
      @point = Travel::AddressIndex::Point.new(latitude: 50.85, longitude: 4.35)
    end
    def available? = true
    def version = "fixture-v1"
    def address(*) = point
    def court(**) = point
  end

  class FakeRouter
    attr_accessor :route_result, :during_lookup
    attr_reader :calls
    def initialize
      @calls = 0
      @route_result = Travel::Router::Route.new(distance_meters: 38_000, duration_seconds: 2100)
    end
    def available? = true
    def route(**)
      @calls += 1
      during_lookup&.call
      route_result
    end
  end

  setup do
    @owner = create_marketplace_account(prefix: "travelowner")
    @candidate = create_marketplace_account(prefix: "travelcandidate")
    @candidate.profile.update!(directory_profile_id: SecureRandom.uuid,
      directory_profile_url: "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}",
      directory_name: @candidate.user.full_name, directory_email: @candidate.user.email_address,
      directory_checked_at: Time.current, directory_professional_address: "Example Street 13, 1000 Brussel")
    @assignment = create_assignment_for(@owner)
    @proposal = create_proposal_for(@assignment, @candidate)
    @proposal.update!(rate_kind: "hourly")
    @index = FakeIndex.new
    @router = FakeRouter.new
    @cache = ActiveSupport::Cache::MemoryStore.new
    clear_enqueued_jobs
  end

  test "rendering queues only the proposal identifier once and never blocks on routing" do
    assert_enqueued_with(job: TravelEstimateJob, args: [ @proposal.id ]) do
      assert_equal :pending, call.status
      assert_equal :pending, call.status
    end
    assert_equal 1, enqueued_jobs.length
    assert_equal 0, @router.calls
  end

  test "computed routes are cached and an address change invalidates them" do
    result = compute
    assert_equal :ready, result.status
    assert_equal 38_000, call.distance_meters
    assert_equal 2100, call.duration_seconds
    assert_equal 1, @router.calls
    assert_no_enqueued_jobs { call }

    @candidate.profile.update!(directory_professional_address: "Example Street 15, 1000 Brussel")
    @proposal.reload
    assert_equal :pending, call.status
  end

  test "fixed legal-task unverified and suspended proposals never request a route" do
    @proposal.update!(rate_kind: "fixed")
    assert_equal :not_applicable, call.status
    @proposal.update!(rate_kind: "hourly")
    @assignment.update!(kind: "legal_task", assignment_subtype: "advice", languages: "EN", court: nil, city: nil)
    @proposal.reload
    assert_equal :not_applicable, call.status
    @assignment.update!(kind: "court_replacement", assignment_subtype: nil, court: "Enterprise Court", city: "Brussels", duration_minutes: 60)
    @candidate.user.update!(suspended_at: Time.current)
    @proposal.reload
    assert_equal :not_applicable, call.status
    assert_equal 0, @router.calls
    assert_no_enqueued_jobs
  end

  test "unmapped addresses and failed engines stay unavailable instead of showing made-up distances" do
    @index.point = nil
    assert_equal :unavailable, compute.status
    assert_equal :unavailable, call.status
    assert_equal 0, @router.calls
    assert_no_enqueued_jobs { call }
  end

  test "eligibility revoked during computation never publishes the route" do
    @router.during_lookup = -> { @candidate.user.update!(suspended_at: Time.current) }
    assert_equal :unavailable, compute.status
    @proposal.reload
    assert_equal :not_applicable, call.status
  end

  test "malformed cached metrics cannot become a displayed route" do
    @cache.define_singleton_method(:read) { |*| { status: :ready, distance_meters: "forged", duration_seconds: -1 } }
    assert_equal :unavailable, call.status
    assert_equal 0, @router.calls
    assert_no_enqueued_jobs
  end

  test "a failed local calculation can retry after five minutes" do
    @router.route_result = nil
    assert_equal :unavailable, compute.status
    assert_no_enqueued_jobs { assert_equal :unavailable, call.status }

    travel 5.minutes + 1.second do
      assert_enqueued_with(job: TravelEstimateJob, args: [ @proposal.id ]) { assert_equal :pending, call.status }
    end
  end

  private

  def call
    Travel::Estimate.call(proposal: @proposal, index: @index, router: @router, cache: @cache)
  end

  def compute
    Travel::Estimate.compute(proposal: @proposal, index: @index, router: @router, cache: @cache)
  end
end
