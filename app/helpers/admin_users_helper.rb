module AdminUsersHelper
  def admin_user_account_status(user)
    return "deletion_pending" if user.deletion_pending?

    user.suspended? || user.erased_at.present? ? "suspended" : "active"
  end
end
