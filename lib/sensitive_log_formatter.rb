class SensitiveLogFormatter < ActiveSupport::Logger::SimpleFormatter
  # Parameter filtering cannot redact signed tokens embedded in URL paths.
  TOKEN_PATH = %r{(/(?:email-verification|directory-verification|passwords)/)[A-Za-z0-9_%+\.=-]{20,}}.freeze

  def call(severity, timestamp, progname, message)
    super.gsub(TOKEN_PATH, '\1[FILTERED]')
  end
end
