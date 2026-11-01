require "test_helper"

class CurrencyFormattingTest < ActionView::TestCase
  tests ApplicationHelper

  test "displayed fees retain both cents digits in each locale" do
    %i[nl fr de en].each do |locale|
      I18n.with_locale(locale) do
        assert_equal(locale == :en ? "180.50" : "180,50", euro_amount(18_050))
        assert_equal "200", euro_amount(20_000)
        assert_equal "180.5", euro_amount(18_050, field: true)
      end
    end
    assert_nil euro_amount(nil)
  end
end
