require "test_helper"
require "yaml"

class TranslationsTest < ActiveSupport::TestCase
  test "all interface languages define the same keys without fallback" do
    expected = translation_leaves(catalogs.fetch("en"))
    %w[nl fr de].each do |locale|
      actual = translation_leaves(catalogs.fetch(locale))
      assert_empty expected.keys - actual.keys, "Missing translation keys in #{locale}"
      assert_empty actual.keys - expected.keys, "Extra translation keys in #{locale}"
      expected.each do |key, value|
        next unless value.is_a?(String)

        assert_kind_of String, actual.fetch(key), "Wrong translation type for #{locale}.#{key}"
        assert_equal value.scan(/%\{([^}]+)\}/).flatten.sort,
          actual.fetch(key).scan(/%\{([^}]+)\}/).flatten.sort,
          "Interpolation differs in #{locale}.#{key}"
      end
    end
  end

  test "locale files do not silently overwrite duplicate YAML keys" do
    locale_files.each do |file|
      assert_empty duplicate_keys(Psych.parse_file(file).root), "Duplicate keys in #{file}"
    end
  end

  test "validation errors and named dates render locally in every language" do
    expected = {
      nl: [ "januari", "te kort", "al in gebruik", "vóór" ],
      fr: [ "janvier", "trop court", "déjà utilisé", "précéder" ],
      de: [ "Januar", "zu kurz", "bereits vergeben", "vor" ],
      en: [ "January", "too short", "already been taken", "before" ]
    }
    expected.each do |locale, (month, short_password, duplicate_email, deadline)|
      I18n.with_locale(locale) do
        assert_includes I18n.l(Date.new(2026, 1, 15), format: :long), month
        assert_includes I18n.l(Time.zone.local(2026, 1, 15, 9, 30), format: :long), month
        user = User.new(first_name: "Test", last_name: "Lawyer", email_address: users(:one).email_address, password: "short")
        assert_not user.valid?
        assert_includes user.errors.full_messages.join(" "), short_password
        assert_includes user.errors.full_messages.join(" "), duplicate_email
        assert_raises(ActiveRecord::RecordInvalid) { user.save! }
        assignment = Assignment.new
        assignment.errors.add(:response_deadline_at, :before_start)
        assert_includes assignment.errors.full_messages.join(" "), deadline
      end
    end
  end

  test "dynamic model values have labels in every interface language" do
    families = [
      [ Assignment::STATUSES + Proposal::STATUSES, "marketplace.status" ],
      [ Assignment::SUBTYPES.values.flatten, "marketplace.assignment_subtypes" ],
      [ Proposal::RATE_KINDS, "marketplace.rate_kinds" ],
      [ PrivacyRequest::KINDS, "trust.privacy_requests.kinds" ],
      [ PrivacyRequest::STATUSES + Report::STATUSES, "trust.statuses" ],
      [ Report::CATEGORIES, "trust.reports.categories" ],
      [ LawyerProfile::VERIFICATION_STATUSES, "admin.users.verification" ],
      [ User::SYSTEM_ROLES, "admin.users.roles" ],
      [ Invoice::STATUSES, "billing.statuses" ]
    ]
    %i[nl fr de en].each do |locale|
      families.each do |values, prefix|
        values.uniq.each { |value| assert I18n.exists?("#{prefix}.#{value}", locale, fallback: false), "Missing #{locale}.#{prefix}.#{value}" }
      end
    end
  end

  test "number grouping and decimals follow the interface language" do
    { nl: "1.250,5", fr: "1 250,5", de: "1.250,5", en: "1,250.5" }.each do |locale, expected|
      I18n.with_locale(locale) do
        assert_equal expected, ActionController::Base.helpers.number_with_delimiter(1250.5)
      end
    end
  end

  private

  def locale_files
    Dir[Rails.root.join("config/locales/*.yml")].sort
  end

  def catalogs
    @catalogs ||= locale_files.each_with_object({}) do |file, result|
      result.deep_merge!(YAML.load_file(file))
    end
  end

  def translation_leaves(tree, prefix = [], result = {})
    tree.each do |key, value|
      path = [ *prefix, key ].join(".")
      value.is_a?(Hash) ? translation_leaves(value, [ *prefix, key ], result) : result[path] = value
    end
    result
  end

  def duplicate_keys(node, prefix = [])
    return [] unless node.respond_to?(:children) && node.children

    if node.is_a?(Psych::Nodes::Mapping)
      seen = []
      node.children.each_slice(2).flat_map do |key, value|
        path = [ *prefix, key.value ]
        duplicates = seen.include?(key.value) ? [ path.join(".") ] : []
        seen << key.value
        duplicates + duplicate_keys(value, path)
      end
    else
      node.children.flat_map { |child| duplicate_keys(child, prefix) }
    end
  end
end
