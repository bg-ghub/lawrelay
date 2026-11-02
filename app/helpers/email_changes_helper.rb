module EmailChangesHelper
  def email_change_support_address
    PlatformOperator.details[:support_email].presence || "support@lawrelay.be"
  end
end
