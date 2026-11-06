require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class PageStylesTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  teardown do
    Capybara.reset_sessions!
    if @account
      AuditEvent.where(actor_user_id: @account.user.id).delete_all
      Session.where(user_id: @account.user.id).delete_all
      LawyerProfile.where(user_id: @account.user.id).delete_all
      @account.user.memberships.delete_all
      User.where(id: @account.user.id).delete_all
      Firm.where(id: @account.firm.id).delete_all
    end
  end

  test "Turbo loads registration CSS then removes it on public navigation and restores it on Back" do
    visit court_cover_path(locale: :en)
    page.execute_script("window.cssNavigationMarker = 'preserved'")
    find(".product-page__actions a[href='#{new_registration_path(locale: :en)}']").click
    assert_current_path new_registration_path(locale: :en)
    assert_selector ".registration-search__submit"
    assert_equal "preserved", page.evaluate_script("window.cssNavigationMarker")
    assert_loaded_styles "account_flow", "auth-copy", "registration_profile"
    assert_equal "16px", page.evaluate_script("getComputedStyle(document.querySelector('.registration-search__submit')).marginTop")

    find("header .brand").click
    assert_current_path root_path(locale: :en)
    assert_loaded_styles "home_pathways", "marketing_copy"
    assert_no_private_styles "account_flow", "auth-copy", "registration_profile", "product_pages"
    assert_equal "preserved", page.evaluate_script("window.cssNavigationMarker")

    page.go_back
    assert_current_path new_registration_path(locale: :en)
    assert_selector ".registration-search__submit"
    assert_loaded_styles "account_flow", "auth-copy", "registration_profile"
    assert_equal "16px", page.evaluate_script("getComputedStyle(document.querySelector('.registration-search__submit')).marginTop")
  end

  test "Turbo brings form styles through sign in and assignment navigation without stale public CSS" do
    @account = create_marketplace_account(prefix: "css-system")
    visit legal_assignments_path(locale: :en)
    find(".product-page__actions a[href='#{new_assignment_path(locale: :en)}']").click
    assert_current_path new_session_path(locale: :en)
    assert_loaded_styles "auth-copy"
    assert_no_private_styles "product_pages"
    assert_selector ".posting-aside .text-link"
    assert_equal "24px", page.evaluate_script("getComputedStyle(document.querySelector('.posting-aside .text-link')).minHeight")
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path new_assignment_path(locale: :en)
    page.execute_script("window.cssNavigationMarker = 'preserved'")
    assert_selector ".court-picker"
    assert_loaded_styles "court_picker", "searchable_select", "proposal_travel"
    assert_no_private_styles "auth-copy", "registration_profile", "product_pages"
    assert_equal "preserved", page.evaluate_script("window.cssNavigationMarker")

    find("header .brand").click
    assert_current_path root_path(locale: :en)
    assert_loaded_styles "home_pathways"
    assert_no_private_styles "court_picker", "searchable_select", "proposal_travel"
    assert_equal "preserved", page.evaluate_script("window.cssNavigationMarker")
  end

  private

  def assert_loaded_styles(*names)
    names.each do |name|
      assert_selector "head link[data-lawrelay-stylesheet='#{name}']", visible: :all
    end
    assert page.evaluate_script("Array.from(document.head.querySelectorAll('link[data-lawrelay-stylesheet]')).every(link => !!link.sheet)")
    order = page.evaluate_script("Array.from(document.head.querySelectorAll('link[data-lawrelay-stylesheet]')).map(link => link.dataset.lawrelayStylesheet)")
    assert_equal order.sort, order
  end

  def assert_no_private_styles(*names)
    names.each { |name| assert_no_selector "head link[data-lawrelay-stylesheet='#{name}']", visible: :all }
  end
end
