module SettingsHelper
  def directory_profile_language_name(value)
    code = value.to_s.downcase
    return value unless code.in?(%w[nl fr de en])

    t("profile_import.language_names.#{code}")
  end
end
