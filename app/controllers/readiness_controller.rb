class ReadinessController < ActionController::API
  # This is intentionally separate from /up: a live Rails process is not
  # necessarily able to serve marketplace requests if the primary database is
  # unavailable. Keep the response deliberately small so an infrastructure
  # probe never becomes an information-disclosure endpoint.
  def show
    self.class.primary_database_ready?

    render json: { status: "ok" }
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.error("Readiness check failed: #{error.class}")
    render json: { status: "unavailable" }, status: :service_unavailable
  end

  def self.primary_database_ready?
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      connection.select_value("SELECT 1")
    end
  end
end
