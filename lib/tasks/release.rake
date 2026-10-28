# frozen_string_literal: true

namespace :release do
  desc "Validate the production configuration before deploying LawRelay"
  task preflight: :environment do
    errors = []

    errors << "RAILS_ENV must be production" unless Rails.env.production?
    validate_app_host(errors)
    validate_operator(errors)
    smtp_checks(errors)
    runtime_checks(errors)

    if errors.any?
      abort([ "Release preflight failed:", *errors.map { |error| "- #{error}" } ].join("\n"))
    end

    puts "Release preflight passed."
  end

  def validate_app_host(errors)
    app_host = ENV["APP_HOST"].to_s.strip
    if app_host.blank?
      errors << "APP_HOST is required"
    elsif app_host.match?(/[\s\/]/) || %w[localhost 127.0.0.1 ::1].include?(app_host)
      errors << "APP_HOST must be a public hostname"
    end
  end

  def validate_operator(errors)
    return if PlatformOperator.configured?

    PlatformOperator::REQUIRED_FIELDS.each do |field|
      next if PlatformOperator.details.fetch(field).present?

      errors << "#{PlatformOperator::ENVIRONMENT_FIELDS.fetch(field)} is required"
    end
  end

  def smtp_checks(errors)
    %w[SMTP_ADDRESS SMTP_USERNAME SMTP_PASSWORD].each do |name|
      errors << "#{name} is required" if ENV[name].blank?
    end
    smtp_port = ENV.fetch("SMTP_PORT", "587")
    smtp_ssl = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SMTP_SSL", "false"))
    smtp_starttls = ActiveModel::Type::Boolean.new.cast(ENV.fetch("SMTP_STARTTLS", "true"))
    supported_transport = (smtp_port == "465" && smtp_ssl && !smtp_starttls) ||
      (smtp_port == "587" && !smtp_ssl && smtp_starttls)

    errors << "SMTP TLS must use 587 with required STARTTLS or 465 with implicit SSL" unless supported_transport
  end

  def runtime_checks(errors)
    adapter = Rails.application.config.active_job.queue_adapter
    errors << "Active Job must use Solid Queue" unless adapter.to_s == "solid_queue"
    errors << "SOLID_QUEUE_IN_PUMA must be true" unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("SOLID_QUEUE_IN_PUMA", "false"))
    errors << "ACTIVE_STORAGE_SERVICE must be local" unless ENV.fetch("ACTIVE_STORAGE_SERVICE", "local") == "local"
    errors << "FORCE_SSL must be true" unless ActiveModel::Type::Boolean.new.cast(ENV.fetch("FORCE_SSL", "true"))
  end
end
