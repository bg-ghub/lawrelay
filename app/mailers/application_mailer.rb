class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "LawRelay <no-reply@lawrelay.be>")
  layout "mailer"
end
