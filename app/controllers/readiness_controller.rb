require "tempfile"

class ReadinessController < ActionController::API
  # This is intentionally separate from /up: a live Rails process is not
  # necessarily able to serve marketplace requests if the primary database is
  # unavailable. Keep the response deliberately small so an infrastructure
  # probe never becomes an information-disclosure endpoint.
  def show
    self.class.database_ready?
    self.class.storage_ready?

    render json: { status: "ok" }
  rescue ActiveRecord::ActiveRecordError, IOError, SystemCallError => error
    Rails.logger.error("Readiness check failed: #{error.class}")
    render json: { status: "unavailable" }, status: :service_unavailable
  end

  def self.database_ready?
    primary_database_ready?
    database_records.each { |record| database_ready_for?(record) }
  end

  def self.primary_database_ready?
    database_ready_for?(ActiveRecord::Base)
  end

  def self.storage_ready?
    storage_path = Rails.root.join("storage")

    Tempfile.create([ "lawrelay-readiness-", ".tmp" ], storage_path) do |file|
      file.write("ok")
      file.flush
      file.fsync
    end
  end

  def self.database_records
    return [] unless Rails.env.production?

    [ SolidCache::Record, SolidQueue::Record, SolidCable::Record ]
  end

  def self.database_ready_for?(record)
    record.connection_pool.with_connection do |connection|
      connection.select_value("SELECT 1")
    end
  end
  private_class_method :database_ready_for?
end
