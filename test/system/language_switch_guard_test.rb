require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class LanguageSwitchGuardTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "language-guard-#{SecureRandom.hex(5)}")
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en)
  end

  teardown do
    Capybara.reset_sessions!
    Session.where(user: @account.user).delete_all
    LawyerProfile.where(user: @account.user).delete_all
    Membership.where(user: @account.user).delete_all
    User.where(id: @account.user.id).delete_all
    Firm.where(id: @account.firm.id).delete_all
  end

  test "cancelling a language change preserves the legal task and its unsaved fields" do
    visit new_assignment_path(locale: :nl)
    find("label.kind-option", text: I18n.t("marketplace.kinds.legal_task", locale: :nl)).click
    fill_in "assignment_title", with: "Unsent example title"
    fill_in "assignment_description", with: "A synthetic description that must stay in this browser."
    fill_in "assignment_languages", with: "NL FR"

    cancel_language_change(:fr, from: :nl)

    assert_current_path new_assignment_path(locale: :nl)
    assert_selector "#assignment_kind_legal_task:checked", visible: :all
    assert_field "assignment_title", with: "Unsent example title"
    assert_field "assignment_description", with: "A synthetic description that must stay in this browser."
    assert_field "assignment_languages", with: "NL FR"
    assert_nil URI(page.current_url).query
  end

  test "untouched defaults and ignored hidden or disabled fields allow switching without a prompt" do
    visit new_assignment_path(locale: :en)
    assert_field "assignment_duration_minutes", with: "60"
    page.execute_script(<<~JS)
      const hidden = document.createElement('input');
      hidden.type = 'hidden';
      document.querySelector('form.assignment-form').append(hidden);
      hidden.value = "changed hidden value";
      document.getElementById('assignment_languages').value = "Changed disabled field";
    JS

    switch_language(:fr)

    assert_current_path new_assignment_path(locale: :fr)
    assert_field "assignment_duration_minutes", with: "60"
  end

  test "changing only the assignment kind triggers the warning" do
    visit new_assignment_path(locale: :en)
    find("label.kind-option", text: "Legal task").click

    cancel_language_change(:fr, from: :en)

    assert_current_path new_assignment_path(locale: :en)
    assert_selector "#assignment_kind_legal_task:checked", visible: :all
  end

  test "select and checkbox changes are protected and reverting them removes the warning" do
    visit new_assignment_path(locale: :en)
    find("#assignment_practice_area option", text: "Commercial law").select_option
    cancel_language_change(:fr, from: :en)
    assert_select_value "assignment_practice_area", "Commercial law"
    find("#assignment_practice_area option[value='']").select_option

    find("#assignment_content_rules_accepted").check
    cancel_language_change(:fr, from: :en)
    assert_checked_field "assignment_content_rules_accepted"
    find("#assignment_content_rules_accepted").uncheck
    fill_in "assignment_title", with: "Temporary edit"
    fill_in "assignment_title", with: ""
    find("label.kind-option", text: "Legal task").click
    find("label.kind-option", text: "Court cover").click

    switch_language(:fr)

    assert_current_path new_assignment_path(locale: :fr)
  end

  test "each language has its own concise confirmation" do
    %i[nl fr de en].each do |locale|
      visit new_assignment_path(locale:)
      fill_in "assignment_title", with: "Unsent translated example"
      target = locale == :fr ? :en : :fr

      cancel_language_change(target, from: locale)

      assert_current_path new_assignment_path(locale:)
      assert_field "assignment_title", with: "Unsent translated example"
    end
  end

  test "confirming the switch navigates without putting field values in the URL or browser storage" do
    visit new_assignment_path(locale: :en)
    value = "Unsent private example #{SecureRandom.hex(5)}"
    fill_in "assignment_title", with: value
    find(".language-menu summary").click

    assert_no_difference "Assignment.count" do
      accept_confirm I18n.t("marketing.language_switch_warning", locale: :en) do
        find(".language-menu a[hreflang='fr']").click
      end
      assert_current_path new_assignment_path(locale: :fr)
    end

    assert_nil URI(page.current_url).query
    assert_field "assignment_title", with: ""
    assert page.evaluate_script(<<~JS, value)
      [localStorage, sessionStorage].every(storage =>
        Object.keys(storage).every(key => !storage.getItem(key).includes(arguments[0]))
      )
    JS
  end

  private

  def switch_language(locale)
    find(".language-menu summary").click unless page.has_selector?(".language-menu[open]", wait: 0)
    find(".language-menu a[hreflang='#{locale}']").click
  end

  def cancel_language_change(locale, from:)
    dismiss_confirm I18n.t("marketing.language_switch_warning", locale: from) do
      switch_language(locale)
    end
  end

  def assert_select_value(id, value)
    assert_equal value, find("##{id}").value
  end
end
