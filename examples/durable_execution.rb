# typed: true
# frozen_string_literal: true

#
# Example: Durable Execution
#
# Shows how Restate.run records side-effect results durably.
# If the handler retries, already-completed steps are skipped
# and their stored results are replayed — giving exactly-once semantics.
#
# Features:
#   - Restate.run          — durable side effect (returns a future)
#   - Restate.run_sync     — same, but returns the value directly (no .await needed)
#   - background: true — offload CPU-heavy work to a real OS Thread
#   - RunRetryPolicy   — custom retry configuration per side effect
#   - TerminalError    — non-retryable failure that stops the invocation
#
# Try it:
#   curl localhost:8080/SubscriptionService/add \
#     -H 'content-type: application/json' \
#     -d '{"user_id": "user_123", "plan": "premium"}'

require 'restate'

class SubscriptionService < Restate::Service
  handler def add(request)
    user_id = request['user_id']
    plan = request['plan']

    # Step 1 — validate (non-retryable failure if invalid)
    # run_sync returns the value directly — no .await needed
    Restate.run_sync('validate') do
      unless %w[basic premium].include?(plan)
        raise Restate::TerminalError.new("Unknown plan: #{plan}", status_code: 400)
      end

      true
    end

    # Step 2 — create subscription with a custom retry policy
    policy = Restate::RunRetryPolicy.new(
      initial_interval: 100,
      max_attempts: 5,
      interval_factor: 2.0,
      max_interval: 5000
    )

    subscription_id = Restate.run_sync('create-subscription', retry_policy: policy) do
      "sub_#{user_id}_#{plan}_#{rand(10_000)}"
    end

    # Step 3 — send confirmation email (background: true offloads to an OS Thread,
    # keeping the fiber event loop free for other handlers)
    Restate.run_sync('send-confirmation', background: true) do
      puts "Sending confirmation for subscription #{subscription_id}"
    end

    { 'subscription_id' => subscription_id, 'user_id' => user_id, 'plan' => plan }
  end
end
