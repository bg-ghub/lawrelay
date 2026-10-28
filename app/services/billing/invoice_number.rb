module Billing
  class InvoiceNumber
    def self.next(date: Date.current)
      prefix = "LR-#{date.year}-"
      last_number = Invoice.where("number LIKE ?", "#{prefix}%").order(number: :desc).pick(:number)
      sequence = last_number.to_s.split("-").last.to_i + 1

      format("%<prefix>s%<sequence>05d", prefix: prefix, sequence: sequence)
    end
  end
end
