require "test_helper"
require_relative "../support/marketplace_test_factory"
require "nokogiri"

class MarketplaceLifecycleMailerTest < ActionMailer::TestCase
  include MarketplaceTestFactory

  LOCALES = %i[nl fr de en].freeze

  setup do
    @owner = create_marketplace_account(prefix: "lifecycleowner")
    @candidate = create_marketplace_account(prefix: "lifecyclecandidate")
    @assignment = create_assignment_for(@owner, title: "Lifecycle <hearing> & task")
    @proposal = create_proposal_for(@assignment, @candidate)
  end

  test "all lifecycle emails use their persisted recipient and locale without address leakage" do
    LOCALES.each do |locale|
      @owner.user.update!(locale: locale)
      @candidate.user.update!(locale: locale)

      events.each do |event, subject, recipient|
        email = I18n.with_locale(:de) { MarketplaceMailer.public_send(event, subject, recipient: recipient).message }
        assert_individual_event(email, event, recipient, locale)
      end
    end
  end

  test "withdrawal and deadline messages default to the assignment creator" do
    assert_equal [ @owner.user.email_address ], MarketplaceMailer.proposal_withdrawn(@proposal).to
    assert_equal [ @owner.user.email_address ], MarketplaceMailer.response_deadline_closed(@assignment).to
  end

  test "stale inactive unverified and administrator recipients receive no event mail" do
    [ { suspended_at: Time.current }, { email_verified_at: nil }, { system_role: "admin" } ].each do |attributes|
      @candidate.user.update!(suspended_at: nil, email_verified_at: Time.current, system_role: "member")
      stale_recipient = User.find(@candidate.user.id)
      @candidate.user.update!(attributes)

      events.each do |event, subject, _recipient|
        assert_no_emails do
          MarketplaceMailer.public_send(event, subject, recipient: stale_recipient).deliver_now
        end
      end
    end
  end

  test "legacy cancellation jobs include only active pending and accepted participants" do
    accepted = create_marketplace_account(prefix: "cancelaccepted")
    declined = create_marketplace_account(prefix: "canceldeclined")
    withdrawn = create_marketplace_account(prefix: "cancelwithdrawn")
    unverified = create_marketplace_account(prefix: "cancelunverified")
    create_proposal_for(@assignment, accepted).update!(status: "accepted")
    create_proposal_for(@assignment, declined).update!(status: "declined")
    create_proposal_for(@assignment, withdrawn).update!(status: "withdrawn")
    create_proposal_for(@assignment, unverified)
    unverified.user.update!(email_verified_at: nil)

    email = MarketplaceMailer.assignment_cancelled(@assignment, locale: :en).message

    assert_equal [ @candidate.user.email_address, accepted.user.email_address ].sort, email.bcc.sort
    [ declined, withdrawn, unverified ].each { |account| assert_not_includes email.bcc, account.user.email_address }
    [ email.html_part, email.text_part ].each do |part|
      email.bcc.each { |address| assert_not_includes part.body.decoded, address }
    end
  end

  test "explicit nil cancellation recipient never falls back to legacy delivery" do
    assert_no_emails { MarketplaceMailer.assignment_cancelled(@assignment, recipient: nil).deliver_now }
  end

  test "current professional verification gates all individual and legacy event mail" do
    [ @candidate.profile, @candidate.firm ].each do |record|
      %w[pending rejected suspended].each do |status|
        stale_recipient = User.includes(:lawyer_profile, memberships: :firm).find(@candidate.user.id)
        assert_predicate stale_recipient, :marketplace_verified?
        record.update!(verification_status: status)

        events.each do |event, subject, _recipient|
          assert_no_emails do
            MarketplaceMailer.public_send(event, subject, recipient: stale_recipient).deliver_now
          end
        end
        assert_no_emails { MarketplaceMailer.assignment_cancelled(@assignment, locale: :en).deliver_now }
        record.update!(verification_status: "verified")
      end
    end
  end

  private

  def events
    [
      [ "new_proposal", @proposal, @owner.user ],
      [ "proposal_accepted", @proposal, @candidate.user ],
      [ "proposal_declined", @proposal, @candidate.user ],
      [ "proposal_withdrawn", @proposal, @owner.user ],
      [ "assignment_matched", @assignment, @owner.user ],
      [ "assignment_cancelled", @assignment, @candidate.user ],
      [ "assignment_completed", @assignment, @candidate.user ],
      [ "assignment_expired", @assignment, @owner.user ],
      [ "assignment_expired", @assignment, @candidate.user ],
      [ "response_deadline_closed", @assignment, @owner.user ]
    ]
  end

  def assert_individual_event(email, event, recipient, locale)
    assert_equal [ recipient.email_address ], email.to
    assert_nil email.bcc
    assert_equal I18n.t("workflow.mailers.#{event}.subject", title: @assignment.title, locale: locale), email.subject
    assert_not_nil email.html_part
    assert_not_nil email.text_part
    html_source = email.html_part.body.decoded
    html = Nokogiri::HTML.fragment(html_source).text.squish
    text = email.text_part.body.decoded
    heading_key = "workflow.mailers.#{event}.heading"
    body_key = if event == "assignment_expired"
      recipient.id == @owner.user.id ? "body_owner" : "body_candidate"
    else
      "body"
    end
    [ heading_key, "workflow.mailers.#{event}.#{body_key}" ].each do |key|
      assert I18n.exists?(key, locale, fallback: false), "#{key} is missing from #{locale}"
    end
    assert_includes html, I18n.t(heading_key, locale: locale)
    body = I18n.t("workflow.mailers.#{event}.#{body_key}", title: @assignment.title, name: @proposal.display_name, locale: locale)
    assert_includes html, body
    assert_includes text, body
    assert_not_includes html_source, @assignment.title
    assert_no_match(/translation missing/i, html_source)
    assert_no_match(/translation missing/i, text)
    action_path = event == "proposal_declined" ? "assignments" : "assignments/#{@assignment.id}"
    assert_includes html_source, "/#{locale}/#{action_path}"
    assert_includes text, "/#{locale}/#{action_path}"
    [ @owner.user, @candidate.user ].each do |user|
      assert_not_includes html, user.email_address
      assert_not_includes text, user.email_address
    end
  end
end
