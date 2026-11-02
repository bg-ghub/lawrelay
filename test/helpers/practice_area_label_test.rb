require "test_helper"

class PracticeAreaLabelTest < ActionView::TestCase
  include ApplicationHelper
  self.fixture_table_names = []

  test "all standard labels resolve to the current language without changing custom text" do
    %i[nl fr de en].each do |source_locale|
      I18n.t("marketplace.practice_areas", locale: source_locale).each do |key, stored_label|
        %i[nl fr de en].each do |locale|
          I18n.with_locale(locale) do
            assert_equal I18n.t("marketplace.practice_areas.#{key}", locale:), practice_area_label(stored_label)
          end
        end
      end
    end

    assert_equal "Custom maritime practice", practice_area_label("Custom maritime practice")
    assert_nil practice_area_label(nil)
  end
end
