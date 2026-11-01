require "test_helper"

class ConfirmationSupportTest < ActionView::TestCase
  tests ApplicationHelper

  test "support instructions use the pending confirmation address passed to the partial" do
    %i[nl fr de en].each do |locale|
      %w[account@example.test listed@advocaat.be].each do |email|
        I18n.with_locale(locale) do
          render partial: "shared/confirmation_support", locals: { email: }

          assert_select ".confirmation-support", text: /#{Regexp.escape(email)}/
          assert_select ".confirmation-support a[href='mailto:support@lawrelay.be']", text: "support@lawrelay.be", count: 1
          assert_select ".confirmation-delivery-note", count: email.end_with?("@advocaat.be") ? 1 : 0
          assert_select ".confirmation-delivery-note", text: /#{Regexp.escape(email)}/ if email.end_with?("@advocaat.be")
        end
      end
    end
  end

  test "the confirmation address is escaped as text in every language" do
    email = "<script>alert('email')</script>@example.test"

    %i[nl fr de en].each do |locale|
      I18n.with_locale(locale) do
        render partial: "shared/confirmation_support", locals: { email: }

        assert_select ".confirmation-support", text: /#{Regexp.escape(email)}/
        assert_select ".confirmation-support script", count: 0
        assert_includes rendered, ERB::Util.html_escape(email)
      end
    end
  end
end
