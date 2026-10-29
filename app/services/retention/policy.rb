module Retention
  module Policy
    UNVERIFIED_REGISTRATION = 30.days
    NOTIFICATION = 90.days
    CLOSED_WORK = 2.years
    RESOLVED_REQUEST = 2.years
    AUDIT_EVENT = 1.year
    ERASED_ACCOUNT = 2.years

    module_function

    def before(period, now: Time.current)
      now - period
    end
  end
end
