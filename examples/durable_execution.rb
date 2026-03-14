# typed: false
# frozen_string_literal: true

#
# Example: Durable Execution
#
# Shows how ctx.run records side-effect results durably.
# If the handler retries, already-completed steps are skipped
# and their stored results are replayed — giving exactly-once semantics.
#
# Features:
#   - ctx.run          — durable side effect (result persisted by Restate)
#   - RunRetryPolicy   — custom retry configuration per side effect
#   - TerminalError    — non-retryable failure that stops the invocation
#
# Try it:
#   curl localhost:8080/SubscriptionService/add \
#     -H 'content-type: application/json' \
#     -d '{"user_id": "user_123", "plan": "premium"}'

require 'restate'

class SubscriptionService < Restate::Service
  handler def add(ctx, request) # rubocop:disable Metrics/MethodLength
    user_id = request['user_id']
    plan = request['plan']

    # Step 1 — validate (non-retryable failure if invalid)
    (ctx.run('validate') do
      unless %w[basic premium].include?(plan)
        raise Restate::TerminalError.new("Unknown plan: #{plan}", status_code: 400)
      end

      true
    end).await

    # Step 2 — create subscription with a custom retry policy
    policy = Restate::RunRetryPolicy.new(
      initial_interval: 100,
      max_attempts: 5,
      interval_factor: 2.0,
      max_interval: 5000
    )

    subscription_id = (ctx.run('create-subscription', retry_policy: policy) do
      "sub_#{user_id}_#{plan}_#{rand(10_000)}"
    end).await

    # Step 3 — send confirmation email
    (ctx.run('send-confirmation') do
      puts "Sending confirmation for subscription #{subscription_id}"
    end).await

    { 'subscription_id' => subscription_id, 'user_id' => user_id, 'plan' => plan }
  end
end

ENDPOINT = Restate.endpoint(SubscriptionService)
