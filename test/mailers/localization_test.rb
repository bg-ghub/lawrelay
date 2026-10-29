require "test_helper"
require_relative "../support/marketplace_test_factory"
require "nokogiri"

class MailerLocalizationTest < ActionMailer::TestCase
  include MarketplaceTestFactory

  LOCALES = %i[nl fr de en].freeze
  MAILER_TRANSLATION_KEYS = %w[
    auth.mailers.email_verification.subject
    auth.mailers.email_verification.heading
    auth.mailers.email_verification.body
    auth.mailers.email_verification.action
    auth.mailers.email_verification.expiry
    auth.mailers.password_reset.subject
    auth.mailers.password_reset.heading
    auth.mailers.password_reset.body
    auth.mailers.password_reset.action
    auth.mailers.password_reset.duration_minutes
    auth.mailers.password_reset.expiry
    directory_mail.confirm.subject
    directory_mail.confirm.greeting
    directory_mail.confirm.body
    directory_mail.confirm.body_html
    directory_mail.confirm.action
    directory_mail.confirm.ignore
    workflow.mailers.view_assignment
    workflow.mailers.browse_assignments
    workflow.mailers.new_proposal.subject
    workflow.mailers.new_proposal.heading
    workflow.mailers.new_proposal.body
    workflow.mailers.proposal_accepted.subject
    workflow.mailers.proposal_accepted.heading
    workflow.mailers.proposal_accepted.body
    workflow.mailers.proposal_declined.subject
    workflow.mailers.proposal_declined.heading
    workflow.mailers.proposal_declined.body
    workflow.mailers.assignment_cancelled.subject
    workflow.mailers.assignment_cancelled.heading
    workflow.mailers.assignment_cancelled.body
  ].freeze

  test "every mailer translation is defined in each supported locale without fallback" do
    LOCALES.each do |locale|
      MAILER_TRANSLATION_KEYS.each do |key|
        assert I18n.exists?(key, locale, fallback: false), "#{key} is missing from #{locale}"
      end
    end
  end

  test "account mailers render both parts in the recipient locale despite a different ambient locale" do
    user = users(:one)

    LOCALES.each do |locale|
      user.update!(locale: locale)
      profile = directory_profile_for(user)

      I18n.with_locale(:de) do
        assert_localized_account_mail(
          EmailVerificationMailer.verify(user).message,
          user: user, locale: locale, subject_key: "auth.mailers.email_verification.subject",
          rendered_keys: %w[auth.mailers.email_verification.heading auth.mailers.email_verification.body auth.mailers.email_verification.action auth.mailers.email_verification.expiry],
          path: "email-verification"
        )
        assert_localized_account_mail(
          PasswordsMailer.reset(user).message,
          user: user, locale: locale, subject_key: "auth.mailers.password_reset.subject",
          rendered_keys: %w[auth.mailers.password_reset.heading auth.mailers.password_reset.body auth.mailers.password_reset.action auth.mailers.password_reset.expiry],
          path: "passwords"
        )

        email = DirectoryVerificationMailer.confirm(profile).message
        assert_equal [ profile.directory_email ], email.to
        assert_equal I18n.t("directory_mail.confirm.subject", locale: locale), email.subject
        assert_mail_parts_are_localized(email) do |html, text, html_source|
          greeting = I18n.t("directory_mail.confirm.greeting", locale: locale, name: profile.directory_name)
          assert_includes html, greeting
          assert_includes text, greeting
          assert_includes html, user.email_address
          assert_includes text, user.email_address
          assert_includes html, I18n.t("directory_mail.confirm.action", locale: locale)
          assert_includes html, I18n.t("directory_mail.confirm.ignore", locale: locale)
          assert_includes text, I18n.t("directory_mail.confirm.ignore", locale: locale)
          assert_includes html_source, "/#{locale}/directory-verification/"
          assert_includes text, "/#{locale}/directory-verification/"
        end
      end
    end
  end

  test "every marketplace event renders HTML and text in its recipient locale" do
    LOCALES.each do |locale|
      owner = create_marketplace_account(prefix: "owner-#{locale}")
      candidate = create_marketplace_account(prefix: "candidate-#{locale}")
      owner.user.update!(locale: locale)
      candidate.user.update!(locale: locale)
      assignment = create_assignment_for(owner, title: "#{locale.upcase} hearing")
      proposal = create_proposal_for(assignment, candidate)

      I18n.with_locale(:en) do
        assert_localized_marketplace_mail(MarketplaceMailer.new_proposal(proposal).message, owner.user, locale, assignment, "new_proposal", "assignment")
        assert_localized_marketplace_mail(MarketplaceMailer.proposal_accepted(proposal).message, candidate.user, locale, assignment, "proposal_accepted", "assignment")
        assert_localized_marketplace_mail(MarketplaceMailer.proposal_declined(proposal).message, candidate.user, locale, assignment, "proposal_declined", "assignments")
      end
    end
  end

  test "cancellation emails are separated by recipient locale without BCC address leakage" do
    owner = create_marketplace_account(prefix: "cancel-owner")
    candidates = LOCALES.to_h do |locale|
      account = create_marketplace_account(prefix: "cancel-#{locale}")
      account.user.update!(locale: locale)
      [ locale, account ]
    end
    assignment = create_assignment_for(owner, title: "Locale-specific cancellation")
    candidates.each_value { |candidate| create_proposal_for(assignment, candidate) }

    I18n.with_locale(:de) do
      candidates.each do |locale, candidate|
        email = MarketplaceMailer.assignment_cancelled(assignment, locale: locale).message
        assert_localized_cancellation(email, candidate.user, locale, assignment)
        (candidates.values - [ candidate ]).each do |other_candidate|
          assert_not_includes email.bcc, other_candidate.user.email_address
        end
      end
    end
  end

  private

  def directory_profile_for(user)
    profile = user.lawyer_profile || user.create_lawyer_profile!(bar_association: "OVB", bar_number: "MAIL-#{SecureRandom.hex(6)}")
    profile.update!(
      directory_profile_id: "mail-#{SecureRandom.hex(6)}",
      directory_profile_url: "https://example.test/directory/#{user.id}",
      directory_name: user.full_name,
      directory_email: "directory-#{user.id}@example.test",
      directory_checked_at: Time.current
    )
    profile
  end

  def assert_localized_account_mail(email, user:, locale:, subject_key:, rendered_keys:, path:)
    assert_equal [ user.email_address ], email.to
    assert_equal I18n.t(subject_key, locale: locale), email.subject
    assert_mail_parts_are_localized(email) do |html, text, html_source|
      rendered_keys.each do |key|
        translation = if key.end_with?("heading")
          I18n.t(key, locale: locale, name: user.first_name)
        elsif key == "auth.mailers.password_reset.expiry"
          duration = I18n.t("auth.mailers.password_reset.duration_minutes", locale: locale, count: 15)
          I18n.t(key, locale: locale, duration: duration)
        else
          I18n.t(key, locale: locale)
        end
        if key.end_with?("heading") || key.end_with?("action")
          assert_includes html, translation
        else
          assert_includes html, translation
          assert_includes text, translation
        end
      end
      assert_includes html_source, "/#{locale}/#{path}/"
      assert_includes text, "/#{locale}/#{path}/"
    end
  end

  def assert_localized_marketplace_mail(email, recipient, locale, assignment, event, path)
    assert_equal [ recipient.email_address ], email.to
    assert_equal I18n.t("workflow.mailers.#{event}.subject", locale: locale, title: assignment.title), email.subject
    assert_mail_parts_are_localized(email) do |html, text, html_source|
      assert_includes html, I18n.t("workflow.mailers.#{event}.heading", locale: locale)
      assert_includes html, assignment.title
      assert_includes text, assignment.title
      action = path == "assignment" ? "view_assignment" : "browse_assignments"
      assert_includes html, I18n.t("workflow.mailers.#{action}", locale: locale)
      assert_includes html_source, "/#{locale}/#{path}"
      assert_includes text, "/#{locale}/#{path}"
    end
  end

  def assert_localized_cancellation(email, recipient, locale, assignment)
    assert_equal [ recipient.email_address ], email.bcc
    assert_equal I18n.t("workflow.mailers.assignment_cancelled.subject", locale: locale, title: assignment.title), email.subject
    assert_mail_parts_are_localized(email) do |html, text, html_source|
      assert_includes html, I18n.t("workflow.mailers.assignment_cancelled.heading", locale: locale)
      assert_includes html, assignment.title
      assert_includes text, assignment.title
      assert_includes html, I18n.t("workflow.mailers.browse_assignments", locale: locale)
      assert_includes html_source, "/#{locale}/assignments"
      assert_includes text, "/#{locale}/assignments"
    end
  end

  def assert_mail_parts_are_localized(email)
    assert_not_nil email.html_part
    assert_not_nil email.text_part
    html_source = email.html_part.body.decoded
    text = email.text_part.body.decoded
    assert_no_match(/translation missing/i, html_source)
    assert_no_match(/translation missing/i, text)
    yield Nokogiri::HTML.fragment(html_source).text.squish, text, html_source
  end
end
