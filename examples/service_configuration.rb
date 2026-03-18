# typed: true
# frozen_string_literal: true

#
# Example: Service Configuration
#
# Shows how to configure service-level and handler-level options that control
# Restate server behavior: timeouts, retention, retry policies, lazy state,
# and access control.
#
# These options are reported via the discovery protocol — they don't change
# SDK runtime behavior, they tell the Restate server how to manage invocations.
#
# Try it:
#   curl localhost:8080/OrderProcessor/my-order/submit \
#     -H 'content-type: application/json' \
#     -d '{"item": "widget", "quantity": 3}'
#   curl localhost:8080/OrderProcessor/my-order/status \
#     -H 'content-type: application/json' -d 'null'

require 'restate'

class OrderRequest < T::Struct
  const :item, String
  const :quantity, Integer
end

class OrderStatus < T::Struct
  const :order_id, String
  const :item, String
  const :quantity, Integer
  const :status, String
end

class OrderProcessor < Restate::VirtualObject
  # ── Service-level configuration ──
  # These apply to all handlers unless overridden per-handler.

  description 'Processes and tracks customer orders'
  metadata 'team' => 'commerce', 'tier' => 'critical'

  # Timeouts (in seconds)
  inactivity_timeout 300          # 5 minutes before considered inactive
  abort_timeout 60                # 1 minute before aborting a stuck handler

  # Retention (in seconds)
  journal_retention 86_400        # Keep journal for 1 day
  idempotency_retention 3600      # Keep idempotency keys for 1 hour

  # State loading — fetch state on demand instead of pre-loading all state
  enable_lazy_state

  # Retry policy for handler invocations
  invocation_retry_policy initial_interval: 0.1,
                          max_interval: 30,
                          max_attempts: 10,
                          exponentiation_factor: 2.0

  # ── Handlers ──

  handler :submit, input: OrderRequest, output: OrderStatus
  # @param ctx [Restate::ObjectContext]
  # @param request [OrderRequest]
  # @return [OrderStatus]
  def submit(ctx, request)
    order_id = ctx.run_sync('create-order') do
      "order_#{request.item}_#{rand(10_000)}"
    end

    ctx.set('status', 'confirmed')
    ctx.set('item', request.item)
    ctx.set('quantity', request.quantity)

    OrderStatus.new(
      order_id: order_id,
      item: request.item,
      quantity: request.quantity,
      status: 'confirmed'
    )
  end

  # Per-handler override: this read-only handler doesn't need lazy state
  # and should be accessible from the public ingress.
  shared :status, output: OrderStatus, enable_lazy_state: false
  # @param ctx [Restate::ObjectSharedContext]
  # @return [OrderStatus]
  def status(ctx)
    OrderStatus.new(
      order_id: ctx.key,
      item: ctx.get('item') || 'unknown',
      quantity: ctx.get('quantity') || 0,
      status: ctx.get('status') || 'unknown'
    )
  end
end
