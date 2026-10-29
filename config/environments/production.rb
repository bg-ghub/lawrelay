require "active_support/core_ext/integer/time"
require_relative "../../lib/sensitive_log_formatter"

Rails.application.configure do
  app_host = ENV.fetch("APP_HOST", "lawrelay.be")
  app_protocol = ENV.fetch("APP_PROTOCOL", "https")
  smtp_address = ENV["SMTP_ADDRESS"].presence
  smtp_port = ENV.fetch("SMTP_PORT", 587).to_i
  smtp_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SMTP_SSL", "false"))
  smtp_starttls = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SMTP_STARTTLS", "true"))

  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  config.action_controller.perform_caching = true
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }
  config.active_storage.service = ENV.fetch("ACTIVE_STORAGE_SERVICE", "local").to_sym

  # Kamal Proxy terminates TLS. These defaults can only be disabled explicitly,
  # which keeps production cookies and redirects secure by default.
  config.assume_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("ASSUME_SSL", "true"))
  config.force_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("FORCE_SSL", "true"))
  healthcheck_paths = %w[/up /ready].freeze
  config.ssl_options = {
    redirect: { exclude: ->(request) { healthcheck_paths.include?(request.path) } },
    hsts: { expires: 1.year, subdomains: true, preload: false }
  }

  config.log_tags = [ :request_id ]
  production_logger = ActiveSupport::Logger.new(STDOUT)
  production_logger.formatter = SensitiveLogFormatter.new
  config.logger = ActiveSupport::TaggedLogging.new(production_logger)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")
  config.silence_healthcheck_path = "/up"
  config.active_support.report_deprecations = false

  config.cache_store = :solid_cache_store
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }

  config.action_mailer.default_url_options = { host: app_host, protocol: app_protocol }
  config.action_mailer.raise_delivery_errors = true

  if smtp_address
    config.action_mailer.delivery_method = :smtp
    config.action_mailer.smtp_settings = {
      address: smtp_address,
      port: smtp_port,
      domain: ENV.fetch("SMTP_DOMAIN", app_host),
      user_name: ENV["SMTP_USERNAME"],
      password: ENV["SMTP_PASSWORD"],
      authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain"),
      ssl: smtp_ssl,
      # Port 587 must upgrade with STARTTLS; do not silently fall back to
      # opportunistic transport encryption.
      enable_starttls: smtp_starttls,
      enable_starttls_auto: false,
      open_timeout: ENV.fetch("SMTP_OPEN_TIMEOUT", 5).to_i,
      read_timeout: ENV.fetch("SMTP_READ_TIMEOUT", 5).to_i
    }.compact
  else
    # A deployment can boot before mail credentials are added, but it cannot
    # silently pretend that messages were sent. The release checklist requires
    # SMTP configuration and a delivery smoke test before real users are invited.
    config.action_mailer.perform_deliveries = false
  end

  config.active_record.dump_schema_after_migration = false
  config.active_record.attributes_for_inspect = [ :id ]

  # Restrict Host headers to the canonical domain and explicitly configured
  # aliases. Health checks are exempt because Kamal may address the container
  # by its internal hostname.
  configured_hosts = [ app_host, *ENV.fetch("ADDITIONAL_HOSTS", "").split(",") ]
    .map(&:strip)
    .reject(&:blank?)
    .uniq
  config.hosts = configured_hosts
  config.host_authorization = { exclude: ->(request) { healthcheck_paths.include?(request.path) } }
end
