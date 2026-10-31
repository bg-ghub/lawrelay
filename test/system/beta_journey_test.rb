require "application_system_test_case"

class BetaJourneyTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @nonce = SecureRandom.hex(5)
    @login_emails = []
    @directory_pages = {}
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    Capybara.reset_sessions!
    clear_enqueued_jobs
    clear_performed_jobs
    ActionMailer::Base.deliveries.clear
    remove_journey_records
  end

  # Synthetic directory pages and captured test email exercise the real signup,
  # confirmation and matching flows without contacting the directory or SMTP.
  # This regression does not replace a trial with real lawyers and inboxes.
  test "three lawyers register, select a proposal, complete and cancel court cover" do
    assert_equal :test, ActionMailer::Base.delivery_method

    with_local_directory do
      perform_enqueued_jobs do
        owner = using_session(:journey_owner) { register_and_confirm("Ada") }
        candidate = using_session(:journey_candidate) { register_and_confirm("Alex") }
        other_candidate = using_session(:journey_other_candidate) { register_and_confirm("Casey") }
        title = "Synthetic beta court cover #{@nonce}"

        using_session(:journey_owner) { post_court_cover(title) }
        assignment = Assignment.find_by!(title:)
        assert_nil assignment.fee_cents

        using_session(:journey_candidate) do
          submit_proposal(assignment, rate: "275", message: "Available for this hearing; commercial law experience.")
        end
        using_session(:journey_other_candidate) do
          submit_proposal(assignment, rate: "250", message: "A separate competing proposal for this hearing.")
          assert_no_text "Available for this hearing; commercial law experience."
        end

        proposal = assignment.proposals.find_by!(user: candidate)
        other_proposal = assignment.proposals.find_by!(user: other_candidate)
        assert_equal 27_500, proposal.rate_cents
        assert_equal "new_proposal", owner.notifications.order(:id).last.kind

        using_session(:journey_owner) do
          visit assignment_path(assignment, locale: :en)
          assert_text candidate.full_name
          assert_no_selector ".contact-card"
          within(".candidate-proposal", text: candidate.full_name) do
            click_button I18n.t("workflow.ui.accept", locale: :en)
          end
          assert_selector ".contact-card a[href='mailto:#{candidate.email_address}']"
          assert_no_selector ".contact-card a[href='mailto:#{other_candidate.email_address}']"
          assert_no_button I18n.t("workflow.ui.accept", locale: :en)
        end

        assert_equal "matched", assignment.reload.status
        assert_equal "accepted", proposal.reload.status
        assert_equal "declined", other_proposal.reload.status
        assert_equal "proposal_accepted", candidate.notifications.order(:id).last.kind
        assert_equal "proposal_declined", other_candidate.notifications.order(:id).last.kind
        assert assignment.audit_events.exists?(action: "assignment.matched")

        using_session(:journey_candidate) do
          visit assignment_path(assignment, locale: :en)
          assert_selector ".contact-card a[href='mailto:#{owner.email_address}']"
          assert_no_selector ".proposal-form"
          visit assignments_path(locale: :en)
          assert_no_link title
        end

        using_session(:journey_other_candidate) do
          visit assignment_path(assignment, locale: :en)
          assert_selector ".status-pill", text: /#{Regexp.escape(I18n.t("marketplace.status.declined", locale: :en))}/i
          assert_no_selector ".contact-card"
          assert_no_text owner.email_address
          assert_no_text candidate.email_address
          assert_no_selector ".proposal-form"
        end

        using_session(:journey_anonymous) do
          visit assignment_path(assignment, locale: :en)
          assert_current_path new_session_path(locale: :en)
          assert_no_text title
          assert_no_selector ".contact-card"
        end

        assert_captured_mail(owner.email_address, "workflow.mailers.new_proposal.subject", title:)
        assert_captured_mail(candidate.email_address, "workflow.mailers.proposal_accepted.subject", title:)
        declined_mail = assert_captured_mail(other_candidate.email_address, "workflow.mailers.proposal_declined.subject", title:)
        assert_not_includes declined_mail.html_part.body.decoded, owner.email_address
        assert_not_includes declined_mail.html_part.body.decoded, candidate.email_address

        using_session(:journey_owner) do
          visit assignment_path(assignment, locale: :en)
          click_button I18n.t("workflow.ui.complete_assignment", locale: :en)
          assert_current_path dashboard_path(locale: :en)
        end
        assert_equal "completed", assignment.reload.status
        assert_equal "assignment_completed", candidate.notifications.order(:id).last.kind
        assert_not other_candidate.notifications.exists?(kind: "assignment_completed", subject: assignment)
        assert_captured_mail(candidate.email_address, "workflow.mailers.assignment_completed.subject", title:)

        using_session(:journey_candidate) do
          visit assignment_path(assignment, locale: :en)
          assert_selector ".status-pill", text: /#{Regexp.escape(I18n.t("marketplace.status.completed", locale: :en))}/i
          assert_no_selector ".proposal-form"
        end

        cancelled_title = "Synthetic beta cancellation #{@nonce}"
        using_session(:journey_owner) { post_court_cover(cancelled_title) }
        cancelled_assignment = Assignment.find_by!(title: cancelled_title)
        using_session(:journey_other_candidate) do
          submit_proposal(cancelled_assignment, rate: "225", message: "Available for the second hearing.")
        end
        using_session(:journey_owner) do
          visit assignment_path(cancelled_assignment, locale: :en)
          accept_confirm { click_button I18n.t("workflow.ui.cancel_assignment", locale: :en) }
          assert_current_path dashboard_path(locale: :en)
        end
        assert_equal "cancelled", cancelled_assignment.reload.status
        assert_equal "assignment_cancelled", other_candidate.notifications.order(:id).last.kind
        assert_captured_mail(other_candidate.email_address, "workflow.mailers.assignment_cancelled.subject", title: cancelled_title)
        using_session(:journey_other_candidate) do
          visit assignment_path(cancelled_assignment, locale: :en)
          assert_selector ".status-pill", text: /#{Regexp.escape(I18n.t("marketplace.status.cancelled", locale: :en))}/i
          assert_no_selector ".contact-card"
          assert_no_selector ".proposal-form"
        end
      end
    end
  end

  private

  def register_and_confirm(first_name)
    login_email = "journey-#{first_name.downcase}-#{@nonce}@example.test"
    listed_email = login_email
    @login_emails << login_email
    last_name = "Journey#{@nonce}"
    source_url = "https://www.advocaat.be/nl/zoek-een-advocaat/advocaat/#{SecureRandom.uuid}"
    @directory_pages[source_url] = <<~HTML
      <main id="main"><h1>#{first_name} #{last_name}</h1>
        <a href="mailto:#{listed_email}">#{listed_email}</a>
      </main>
    HTML

    visit new_registration_path(locale: :en)
    fill_in "registration_directory_profile_url", with: source_url
    click_button I18n.t("signup_profile.fetch", locale: :en)
    assert_text listed_email
    assert_no_selector "input[name='registration[email_address]']", visible: :all
    fill_in "registration_password", with: "password1234"
    fill_in "registration_password_confirmation", with: "password1234"
    find("#registration_terms_accepted").check
    find("form.assignment-form input[type='submit']").click
    assert_current_path verification_status_path(locale: :en)

    user = User.find_by!(email_address: login_email)
    assert_not user.marketplace_verified?
    visit new_assignment_path(locale: :en)
    assert_current_path verification_status_path(locale: :en)

    visit captured_email_path(login_email, "/email-verification/")
    assert_not user.reload.email_verified?, "Opening an email link must not confirm it"
    click_button I18n.t("auth.email_verifications.review.submit", locale: :en)
    assert_current_path dashboard_path(locale: :en)
    assert_predicate user.reload, :email_verified?
    assert_predicate user, :marketplace_verified?
    assert_predicate user.lawyer_profile.reload, :directory_email_verified?

    # Exercise the actual password sign-in rather than relying on signup's session.
    find(".header-logout").click
    assert_current_path new_session_path(locale: :en)
    fill_in "email_address", with: login_email
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
    user
  end

  def post_court_cover(title)
    visit new_assignment_path(locale: :en)
    fill_in "assignment_title", with: title
    fill_in "assignment_description", with: "Court cover request without client or case details."
    choose_searchable_option("assignment_practice_area", label: "Commercial law")
    set_datetime("assignment_response_deadline_at", 2.days.from_now)
    set_datetime("assignment_hearing_at", 3.days.from_now)
    fill_in "assignment_duration_minutes", with: "60"
    find("#assignment_court").click
    find("#assignment-court-options [role='option'][data-other='true']").click
    fill_in "assignment_court_other", with: "Synthetic court"
    fill_in "assignment_city", with: "Brussels"
    assert_field "assignment_fee_cents", with: ""
    find("#assignment_content_rules_accepted").check
    click_button I18n.t("marketplace.form.submit", locale: :en)
    assert_selector "h1", text: title
    assert_selector ".proposal-panel__price strong", text: I18n.t("marketplace.fee_unspecified", locale: :en)
  end

  def submit_proposal(assignment, rate:, message:)
    visit assignment_path(assignment, locale: :en)
    assert_no_selector ".contact-card"
    fill_in "proposal_rate_cents", with: rate
    fill_in "proposal_message", with: message
    click_button I18n.t("marketplace.show.submit", locale: :en)
    assert_selector ".status-pill", text: /#{Regexp.escape(I18n.t("marketplace.status.pending", locale: :en))}/i
    assert_no_selector ".contact-card"
  end

  def set_datetime(id, time)
    page.execute_script(<<~JAVASCRIPT, id, time.strftime("%Y-%m-%dT%H:%M"))
      const input = document.getElementById(arguments[0]);
      input.value = arguments[1];
      input.dispatchEvent(new Event("input", { bubbles: true }));
      input.dispatchEvent(new Event("change", { bubbles: true }));
    JAVASCRIPT
  end

  def captured_email_path(recipient, path)
    mail = ActionMailer::Base.deliveries.reverse.find do |delivery|
      delivery.to.include?(recipient) && delivery.html_part.body.decoded.include?(path)
    end
    assert mail, "Expected a captured confirmation email for #{recipient}"
    link = Nokogiri::HTML(mail.html_part.body.decoded).at_css("a[href*='#{path}']")
    assert link, "Expected a confirmation action in the captured email"
    URI(link["href"]).request_uri
  end

  def assert_captured_mail(recipient, subject_key, **attributes)
    subject = I18n.t(subject_key, locale: :en, **attributes)
    mail = ActionMailer::Base.deliveries.find { |delivery| delivery.to.include?(recipient) && delivery.subject == subject }
    assert mail, "Expected captured #{subject_key} email"
    mail
  end

  def with_local_directory
    lookup = Directory::AdvocaatBeProfileLookup
    original_lookup = lookup.method(:call)
    pages = @directory_pages
    lookup.define_singleton_method(:call) do |profile_url:, full_name:|
      original_lookup.call(profile_url:, full_name:, fetcher: ->(uri) { pages.fetch(uri.to_s) })
    end
    signup = Directory::SignupProfile
    original_signup = signup.method(:call)
    signup.define_singleton_method(:call) do |profile_url:|
      original_signup.call(profile_url:, fetcher: ->(uri) { pages.fetch(uri.to_s) })
    end
    yield
  ensure
    lookup.define_singleton_method(:call, original_lookup) if original_lookup
    signup.define_singleton_method(:call, original_signup) if original_signup
  end

  def remove_journey_records
    users = User.where(email_address: @login_emails)
    user_ids = users.pluck(:id)
    firm_ids = Membership.where(user_id: user_ids).pluck(:firm_id)
    assignment_ids = Assignment.where(firm_id: firm_ids).pluck(:id)

    AuditEvent.where(actor_user_id: user_ids).or(AuditEvent.where(firm_id: firm_ids)).delete_all
    Notification.where(user_id: user_ids).delete_all
    Proposal.where(user_id: user_ids).or(Proposal.where(assignment_id: assignment_ids)).delete_all
    Assignment.where(id: assignment_ids).delete_all
    Session.where(user_id: user_ids).delete_all
    LawyerProfile.where(user_id: user_ids).delete_all
    Membership.where(user_id: user_ids).delete_all
    users.delete_all
    Firm.where(id: firm_ids).delete_all
  end
end
