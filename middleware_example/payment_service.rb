# frozen_string_literal: true

require 'restate'

class PaymentService < Restate::Service
  handler :charge, input: String, output: String
  # @param ctx [Restate::Context]
  # @param amount [String]
  # @return [String]
  def charge(ctx, amount)
    tenant = Thread.current[:tenant_id] || 'unknown'

    tx_id = ctx.run_sync('process-payment') do
      "tx_#{tenant}_#{amount}_#{rand(10_000)}"
    end

    ctx.run_sync('send-receipt') do
      puts "Sending receipt for #{tx_id} to tenant #{tenant}"
    end

    "charged #{amount} for tenant #{tenant} (tx: #{tx_id})"
  end
end
