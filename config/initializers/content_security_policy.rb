# A restrictive baseline for server-rendered Rails, Turbo, and import maps.
# Add third-party origins deliberately and document why they are needed.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.base_uri :self
    policy.connect_src :self
    policy.font_src :self, :data
    policy.form_action :self
    policy.frame_ancestors :none
    policy.frame_src :none
    policy.img_src :self, :data
    policy.manifest_src :self
    policy.object_src :none
    policy.script_src :self
    policy.style_src :self
    policy.worker_src :self

    if Rails.env.production? && ENV["UMAMI_WEBSITE_ID"].present?
      policy.connect_src :self, "https://analytics.lawrelay.be"
      policy.script_src :self, "https://analytics.lawrelay.be"
    end
  end

  config.content_security_policy_nonce_generator = ->(_request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src style-src]
  config.content_security_policy_nonce_auto = true
  config.content_security_policy_report_only = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("CSP_REPORT_ONLY", "false")
  )
end
