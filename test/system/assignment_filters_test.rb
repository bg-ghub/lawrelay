require "application_system_test_case"
require_relative "../support/marketplace_test_factory"

class AssignmentFiltersTest < ApplicationSystemTestCase
  include MarketplaceTestFactory

  setup do
    @account = create_marketplace_account(prefix: "assignment-filters")
    @assignment = create_assignment_for(@account, title: "Antwerp hearing")
    create_assignment_for(@account, title: "Brussels hearing")
    visit new_session_path(locale: :en)
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path dashboard_path(locale: :en), wait: 10
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    Capybara.reset_sessions!
    page.current_window.resize_to(1400, 1400)
    ids = @account.firm.assignments.pluck(:id)
    AuditEvent.where(actor_user_id: @account.user.id).or(AuditEvent.where(firm_id: @account.firm.id)).delete_all
    Notification.where(user_id: @account.user.id).delete_all
    Proposal.where(assignment_id: ids).delete_all
    Assignment.where(id: ids).delete_all
    Session.where(user_id: @account.user.id).delete_all
    LawyerProfile.where(id: @account.profile.id).delete_all
    @account.user.memberships.delete_all
    User.where(id: @account.user.id).delete_all
    Firm.where(id: @account.firm.id).delete_all
  end

  test "mobile filters are discoverable before results and desktop keeps its expanded sidebar" do
    %i[nl fr de en].each do |locale|
      resize_viewport(390)
      visit assignments_path(locale:)
      assert_no_selector ".assignment-filters[open]"
      assert_selector ".assignment-filters__summary", text: I18n.t("marketplace.index.filters_aria", locale:)
      assert page.evaluate_script(<<~JS), "Mobile filters must precede assignment results"
        document.querySelector('.filter-panel').getBoundingClientRect().bottom <=
          document.querySelector('.assignment-results').getBoundingClientRect().top
      JS
      find(".assignment-filters__summary").send_keys(:enter)
      assert_selector ".assignment-filters[open]"
      assert_selector "#q"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, 390
    end

    resize_viewport(1280)
    assert_selector ".assignment-filters[open]"
    assert_no_selector ".assignment-filters__summary", visible: :visible
    assert page.evaluate_script(<<~JS), "Desktop filters must remain beside assignment results"
      document.querySelector('.filter-panel').getBoundingClientRect().right <
        document.querySelector('.assignment-results').getBoundingClientRect().left
    JS
  end

  test "automatic filtering keeps the search focus and open filters while advancing browser history" do
    resize_viewport(390)
    visit assignments_path(locale: :en)
    find(".assignment-filters__summary").click
    search = find("#q")
    search.click
    scroll = page.evaluate_script("window.scrollY")
    search.send_keys("Ant")
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_no_selector "#assignment-results .assignment-card", text: "Brussels hearing"
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"
    assert_selector "#city-search[role='combobox']", count: 1
    assert_selector "#practice_area-search[role='combobox']", count: 1
    assert_equal "q", page.driver.browser.switch_to.active_element.attribute("id")
    assert_in_delta scroll, page.evaluate_script("window.scrollY"), 2
    assert_selector ".assignment-filters[open]"

    page.driver.browser.switch_to.active_element.send_keys("werp")
    assert_current_path(%r{/en/assignments\?q=Antwerp(?:&|$)})
    assert_equal "q", page.driver.browser.switch_to.active_element.attribute("id")
    assert_equal "Antwerp", find("#q").value
    assert_selector "#city-search[role='combobox']", count: 1
    assert_selector "#practice_area-search[role='combobox']", count: 1

    page.go_back
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_field "q", with: "Ant", visible: :all
    assert_field "q", with: "Ant"
    find(".filter-panel .text-link").click
    assert_current_path assignments_path(locale: :en)
    assert_selector "#assignment-results .assignment-card", text: "Brussels hearing"
    within "#assignment-results" do
      click_link "Antwerp hearing"
    end
    assert_current_path assignment_path(@assignment, locale: :en)
    assert_selector ".assignment-detail h1", text: "Antwerp hearing"
  end

  test "without JavaScript the expanded filters submit a normal GET" do
    resize_viewport(390)
    page.driver.browser.execute_cdp("Emulation.setScriptExecutionDisabled", value: true)
    visit assignments_path(locale: :en)
    assert_selector ".assignment-filters[open]"
    fill_in "q", with: "Ant"
    click_button I18n.t("marketplace.index.apply_filters", locale: :en)
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"
    assert_no_selector "#assignment-results .assignment-card", text: "Brussels hearing"
  end

  test "Back restores radio and searchable filter values from the history URL" do
    initial = { q: "Ant", kind: "court_replacement", city: "Brussels", practice_area: "Commercial law" }

    [ :kind, :city, :practice_area ].each do |changed|
      visit assignments_path(locale: :en, **initial)
      if changed == :kind
        find("#kind_legal_task").choose
      else
        choose_searchable_option(changed.to_s, value: "")
      end
      updated = initial.merge(changed => changed == :kind ? "legal_task" : "")
      changed_value = Regexp.escape(URI.encode_www_form_component(updated.fetch(changed)))
      assert_current_path(%r{[?&]#{changed}=#{changed_value}(?:&|$)})
      assert_equal updated.stringify_keys, URI.decode_www_form(URI.parse(page.current_url).query).to_h
      assert_selector "#assignment-results:not([busy])"
      assert_selector "#city-search[role='combobox']", count: 1
      assert_selector "#practice_area-search[role='combobox']", count: 1

      go_back_to assignments_path(locale: :en, **initial)
      assert_current_path assignments_path(locale: :en, **initial)
      assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"
      assert_field "q", with: "Ant"
      assert_checked_field "kind_court_replacement"
      assert_selector "select#city", visible: :all do |select|
        select.value == "Brussels"
      end
      assert_field "city-search", with: "Brussels"
      assert_selector "select#practice_area", visible: :all do |select|
        select.value == "Commercial law"
      end
      assert_field "practice_area-search", with: "Commercial law"
    end
  end

  test "Back cancels a pending filter request before it can advance history again" do
    visit assignments_path(locale: :en)
    fill_in "q", with: "Ant"
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_selector "#city-search[role='combobox']"
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      const form = document.querySelector('.filter-form');
      form.addEventListener('turbo:submit-end', () => {
        document.documentElement.dataset.filterRequestEnded = 'true';
      });
      window.fetch = async (...args) => {
        const url = new URL(args[0].url || args[0], location.href);
        if (url.pathname === '/en/assignments' && url.searchParams.get('q') === 'Antwerp') {
          const signal = args[1].signal;
          await new Promise((resolve, reject) => {
            window.releaseFilterRequest = () => {
              window.fetch = originalFetch;
              resolve();
            };
            signal.addEventListener('abort', () => {
              document.documentElement.dataset.filterRequestAborted = 'true';
              reject(new DOMException('Aborted', 'AbortError'));
            }, { once: true });
            document.documentElement.dataset.filterRequestPaused = 'true';
          });
        }
        return originalFetch(...args);
      };
    JS
    find("#q").send_keys("werp")
    assert_selector "html[data-filter-request-paused='true']"

    go_back_to assignments_path(locale: :en)
    page.execute_script("window.releaseFilterRequest()")

    assert_selector "html[data-filter-request-ended='true']"
    assert_selector "html[data-filter-request-aborted='true']"
    assert_current_path assignments_path(locale: :en)
    assert_field "q", with: ""
    assert_selector "#assignment-results .assignment-card", text: "Brussels hearing"
    assert_no_selector "#assignment-results[busy]"
  end

  test "Back refetches current results instead of restoring an outdated board snapshot" do
    initial = { q: "Ant", kind: "court_replacement", city: "Brussels", practice_area: "Commercial law" }
    visit assignments_path(locale: :en, **initial)
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"

    find("#kind_legal_task").choose
    assert_current_path(%r{[?&]kind=legal_task(?:&|$)})
    assert_no_selector "#assignment-results .assignment-card"
    @assignment.update!(title: "Antwerp hearing updated on the server")

    go_back_to assignments_path(locale: :en, **initial)

    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing updated on the server"
    assert_checked_field "kind_court_replacement"
    assert_field "q", with: "Ant"
    assert_field "city-search", with: "Brussels"
    assert_field "practice_area-search", with: "Commercial law"
  end

  test "a delayed filter frame promotion cannot cancel Back while restoration is loading" do
    initial = { q: "Ant", kind: "court_replacement", city: "Brussels", practice_area: "Commercial law" }
    visit assignments_path(locale: :en, **initial)
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"
    page.execute_script(<<~JS)
      const originalFetch = window.fetch;
      document.addEventListener('turbo:before-visit', event => {
        const url = new URL(event.detail.url, location.href);
        if (window.filterPromotionReleased && url.searchParams.get('kind') === 'legal_task') {
          queueMicrotask(() => { document.documentElement.dataset.filterPromotionAttempted = 'true'; });
        }
      });
      window.fetch = async (...args) => {
        const url = new URL(args[0].url || args[0], location.href);
        if (url.pathname === '/en/assignments' && url.searchParams.get('kind') === 'court_replacement') {
          const signal = args[1].signal;
          await new Promise((resolve, reject) => {
            window.releaseBoardRestoration = () => { window.fetch = originalFetch; resolve(); };
            signal.addEventListener('abort', () => {
              document.documentElement.dataset.filterRestorationAborted = 'true';
              reject(new DOMException('Aborted', 'AbortError'));
            }, { once: true });
            document.documentElement.dataset.filterRestorationPaused = 'true';
          });
        }
        const response = await originalFetch(...args);
        if (url.pathname === '/en/assignments' && url.searchParams.get('kind') === 'legal_task') {
          const clone = response.clone.bind(response);
          let reads = 0;
          response.clone = () => {
            const copy = clone();
            const text = copy.text.bind(copy);
            copy.text = async () => {
              const html = await text();
              if (++reads === 2) {
                await new Promise(resolve => {
                  window.releaseFilterPromotion = () => { window.filterPromotionReleased = true; resolve(); };
                  document.documentElement.dataset.filterPromotionPaused = 'true';
                });
              }
              return html;
            };
            return copy;
          };
        }
        return response;
      };
    JS
    find("#kind_legal_task").choose
    assert_selector "html[data-filter-promotion-paused='true']"
    assert_no_selector "#assignment-results .assignment-card"
    @assignment.update!(title: "Antwerp hearing after delayed promotion")

    page.go_back
    assert_selector "html[data-filter-restoration-paused='true']"
    page.execute_script("window.releaseFilterPromotion()")
    assert_selector "html[data-filter-promotion-attempted='true']"
    assert_no_selector "html[data-filter-restoration-aborted='true']"
    page.execute_script("window.releaseBoardRestoration()")

    assert_current_path assignments_path(locale: :en, **initial)
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing after delayed promotion"
    assert_checked_field "kind_court_replacement"
    assert_field "city-search", with: "Brussels"
    assert_field "practice_area-search", with: "Commercial law"
    assert_no_selector "#assignment-results[busy]"
  end

  test "Enter submits search once without leaving a pending duplicate history entry" do
    visit assignments_path(locale: :en)
    find("#q").send_keys("Ant", :enter)
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_selector "#city-search[role='combobox']", count: 1
    page.driver.browser.execute_async_script("setTimeout(arguments[0], 450)")

    page.go_back

    assert_current_path assignments_path(locale: :en)
    assert_field "q", with: ""
    assert_selector "#assignment-results .assignment-card", text: "Brussels hearing"
  end

  test "a revoked session returns filtering to sign in and preserves the safe destination" do
    visit assignments_path(locale: :en)
    Session.where(user_id: @account.user.id).delete_all

    fill_in "q", with: "Ant"

    assert_current_path new_session_path(locale: :en)
    assert_full_shell
    assert_selector "form.assignment-form input[autocomplete='username']"
    assert_no_text "Content missing"
    assert_no_selector "turbo-frame#assignment-results"
    fill_in "email_address", with: @account.user.email_address
    fill_in "password", with: "password1234"
    find("form.assignment-form input[type='submit']").click
    assert_current_path(%r{/en/assignments\?q=Ant(?:&|$)})
    assert_selector "#assignment-results .assignment-card", text: "Antwerp hearing"
    assert_no_selector "#assignment-results .assignment-card", text: "Brussels hearing"
  end

  test "a verification gate opens as a full page when filtering" do
    visit assignments_path(locale: :en)
    @account.user.update!(email_verified_at: nil)

    fill_in "q", with: "Ant"

    assert_current_path verification_status_path(locale: :en)
    assert_full_shell
    assert_selector ".verification-status-page"
    assert_no_text "Content missing"
    assert_no_selector "turbo-frame#assignment-results"
  end

  private

  def go_back_to(path)
    page.execute_script(<<~JS, path)
      const expected = new URL(arguments[0], location.href).href;
      document.documentElement.removeAttribute('data-filter-history-restored');
      const restored = event => {
        if (event.detail.url !== expected) return;
        document.documentElement.dataset.filterHistoryRestored = 'true';
        document.removeEventListener('turbo:load', restored);
      };
      document.addEventListener('turbo:load', restored);
    JS
    page.go_back
    assert_selector "html[data-filter-history-restored='true']"
  end

  def assert_full_shell
    assert_selector "html[lang='en']"
    assert_selector "body.site-shell"
    assert_selector "header.site-header"
    assert_selector "footer.site-footer"
    assert_selector "main#main-content"
  end

  def resize_viewport(width)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width:, height: 900, deviceScaleFactor: 1, mobile: false)
    assert_equal width, page.evaluate_script("window.innerWidth")
  end
end
