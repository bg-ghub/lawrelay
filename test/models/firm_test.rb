require "test_helper"

class FirmTest < ActiveSupport::TestCase
  test "beta posting access follows firm verification rather than billing" do
    firm = Firm.create!(name: "Beta firm", verification_status: "pending")

    refute firm.posting_access?
    firm.update!(verification_status: "verified", verified_at: Time.current)
    assert firm.posting_access?
  end

  test "paid mode retains billing gate" do
    firm = Firm.create!(name: "Paid firm", verification_status: "verified", verified_at: Time.current)

    with_env("LAWRELAY_RELEASE_MODE" => "paid", "LAWRELAY_BILLING_ENFORCED" => "true") do
      refute firm.posting_access?
    end
  end

  private

  def with_env(values)
    old = values.to_h { |key, _| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
