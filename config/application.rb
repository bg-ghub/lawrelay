require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module LawRelay
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    config.time_zone = "Brussels"
    config.i18n.available_locales = %i[nl fr de en]
    config.i18n.default_locale = :nl
    config.i18n.fallbacks = {
      nl: %i[nl en],
      fr: %i[fr en],
      de: %i[de en],
      en: %i[en]
    }

    config.action_dispatch.default_headers.merge!(
      "Referrer-Policy" => "strict-origin-when-cross-origin",
      "Permissions-Policy" => "camera=(), microphone=(), geolocation=(), payment=()",
      "X-Content-Type-Options" => "nosniff"
    )

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
