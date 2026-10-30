# frozen_string_literal: true

class GeoChallengesController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :enforce_geo_challenge
  content_security_policy only: %i[show create] do |policy|
    policy.worker_src :self, :blob
  end
  rate_limit to: 12, within: 5.minutes, only: %i[challenge_json create], by: -> { request.remote_ip }, with: :rate_limited

  def show; end

  def challenge_json
    nonce = SecureRandom.hex(16)
    session[:geo_challenge] = { "nonce" => nonce, "expires_at" => AltchaService::TTL.from_now.to_i }
    render json: AltchaService.generate_challenge(nonce:)
  end

  def create
    proof = session.delete(:geo_challenge)
    if proof.present? && proof["expires_at"].to_i > Time.current.to_i && AltchaService.verify_solution(params[:altcha], nonce: proof["nonce"])
      cookies.signed[:geo_verified] = {
        value: "verified", expires: 24.hours.from_now, httponly: true,
        secure: Rails.env.production?, same_site: :lax
      }
      destination = local_path(cookies.signed[:geo_return_to]) || root_path(locale: I18n.locale)
      cookies.delete(:geo_return_to)
      redirect_to destination
    else
      @error = true
      render :show, status: :unprocessable_content
    end
  end

  private

  def rate_limited
    @error = true
    render :show, status: :too_many_requests
  end

  def local_path(value)
    path = value.to_s
    path if path.start_with?("/") && !path.start_with?("//") && !path.include?("\\")
  end
end
