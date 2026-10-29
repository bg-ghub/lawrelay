class EmailVerificationDeliveryJob < ActionMailer::MailDeliveryJob
  discard_on ActiveJob::DeserializationError
  retry_on Onboarding::MailTransport::TemporaryFailure, wait: 1.minute, attempts: 3

  def perform(mailer, mail_method, delivery_method, args:, kwargs: nil, params: nil)
    user = args.first
    return unless user.is_a?(User) && user.reload.active? && !user.email_verified?

    mailer_class = params ? mailer.constantize.with(params) : mailer.constantize
    delivery = kwargs ? mailer_class.public_send(mail_method, *args, **kwargs) : mailer_class.public_send(mail_method, *args)
    Onboarding::MailTransport.protect(delivery.message)
    delivery.public_send(delivery_method)
  end
end
