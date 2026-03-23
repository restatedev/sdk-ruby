# frozen_string_literal: true

require 'restate'

# A simple receipt service that reads tenant from headers (set by outbound middleware on the caller).
class ReceiptService < Restate::Service
  handler :send_receipt, input: String, output: String
  # @param tx_id [String]
  # @return [String]
  def send_receipt(tx_id)
    tenant = Thread.current[:tenant_id] || 'unknown'
    "receipt for #{tx_id} sent to tenant #{tenant}"
  end
end

class PaymentService < Restate::Service
  handler :charge, input: String, output: String
  # @param amount [String]
  # @return [String]
  def charge(amount)
    tenant = Thread.current[:tenant_id] || 'unknown'

    tx_id = Restate.run_sync('process-payment') do
      "tx_#{tenant}_#{amount}_#{rand(10_000)}"
    end

    # Call ReceiptService — outbound middleware automatically injects x-tenant-id
    receipt = ReceiptService.call.send_receipt(tx_id).await

    "charged #{amount} for tenant #{tenant} (#{receipt})"
  end
end
