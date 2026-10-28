module Billing
  class ManualPeppolInvoiceService
    def initialize(invoice)
      @invoice = invoice
    end

    def call
      @invoice.update!(peppol_status: "manual_required")
      @invoice
    end
  end
end
