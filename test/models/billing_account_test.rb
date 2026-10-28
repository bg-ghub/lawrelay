require "test_helper"

class BillingAccountTest < ActiveSupport::TestCase
  test "founding beta requires an explicit active unexpired grant" do
    account = BillingAccount.create!(firm: Firm.create!(name: "Beta Firm #{SecureRandom.uuid}"))

    assert_not account.posting_access?

    account.update!(status: "active", complimentary_access_until: 1.day.from_now)
    assert account.posting_access?

    account.update!(complimentary_access_until: 1.minute.ago)
    assert_not account.posting_access?
  end

  test "paid plan requires an active subscription with an unexpired billing period" do
    account = BillingAccount.create!(
      firm: Firm.create!(name: "Paid Firm #{SecureRandom.uuid}"),
      plan_key: "lawrelay_office",
      status: "pending"
    )
    subscription = account.subscriptions.create!(
      provider: "manual", plan_key: "lawrelay_office", status: "pending", amount_cents: 4900
    )

    assert_not account.posting_access?
    subscription.update!(status: "active", current_period_ends_at: 1.day.from_now)
    assert account.posting_access?

    subscription.update!(current_period_ends_at: 1.minute.ago)
    assert_not account.posting_access?
  end

  test "billing enforcement defaults on in production and remains opt-in locally" do
    original = ENV.delete("LAWRELAY_BILLING_ENFORCED")

    assert Firm.billing_enforced?(environment: ActiveSupport::StringInquirer.new("production"))
    assert_not Firm.billing_enforced?(environment: ActiveSupport::StringInquirer.new("test"))
  ensure
    ENV["LAWRELAY_BILLING_ENFORCED"] = original if original
  end
end
