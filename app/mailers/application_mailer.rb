class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch("MAIL_FROM", "LawRelay <no-reply@lawrelay.be>"),
    return_path: -> { Onboarding::MailTransport.return_path }
  layout "mailer"
  helper ApplicationHelper

  before_deliver { Onboarding::MailTransport.protect(message) }
end
