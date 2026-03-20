# typed: true
# frozen_string_literal: true

#
# Example: Workflows
#
# A Workflow runs exactly once per key. Its main handler executes a
# durable sequence of steps, while shared handlers let external
# callers interact with the running workflow via promises and state.
#
# Features:
#   - main handler             — entry point, runs once per workflow ID
#   - Restate.promise          — block until a signal arrives
#   - Restate.resolve_promise  — deliver a value to a waiting promise
#   - Restate.set / Restate.get — workflow state visible to shared handlers
#
# Try it:
#   # Start the workflow
#   curl localhost:8080/UserSignup/run  \
#     -H 'content-type: application/json' \
#     -H 'idempotency-key: signup-user42' \
#     -d '"user42@example.com"'
#
#   # In another terminal, approve the user
#   curl localhost:8080/UserSignup/approve \
#     -H 'content-type: application/json' \
#     -d '"approved by admin"'
#
#   # Check status
#   curl localhost:8080/UserSignup/status \
#     -H 'content-type: application/json' \
#     -d 'null'

require 'restate'

class UserSignup < Restate::Workflow
  main def run(email)
    user_id = Restate.run_sync('create-account') do
      "user_#{email.gsub(/[^a-zA-Z0-9]/, '_')}"
    end

    Restate.set('status', 'waiting_for_approval')

    # Wait for an external approval signal
    approval = Restate.promise('approval')
    Restate.set('status', 'approved')

    # Activate account
    Restate.run_sync('activate') { puts "Activating #{user_id} — #{approval}" }

    Restate.set('status', 'active')
    { 'user_id' => user_id, 'email' => email, 'approval' => approval }
  end

  # Signal handler — delivers the approval value to the waiting workflow.
  handler def approve(reason)
    Restate.resolve_promise('approval', reason)
    'approval sent'
  end

  # Query handler — returns current workflow status.
  handler def status
    Restate.get('status') || 'unknown'
  end
end
