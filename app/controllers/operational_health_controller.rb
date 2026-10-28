class OperationalHealthController < ActionController::API
  # Public probes deliberately reveal no job counts, payloads, or failure text.
  def show
    if Operations::QueueHealth.healthy?
      render json: { status: "ok" }
    else
      render json: { status: "unavailable" }, status: :service_unavailable
    end
  end
end
