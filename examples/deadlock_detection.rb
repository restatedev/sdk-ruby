# frozen_string_literal: true

# Deadlock Detection Middleware Example
#
# Demonstrates how the DeadlockDetection middleware catches re-entrant
# VirtualObject calls that would otherwise block forever.
#
# == The Problem
#
# Restate VirtualObjects serialize exclusive handler access per key. If an
# exclusive handler on key "x" calls another exclusive handler on the same
# VO key "x", the second call waits for the first to finish — which never
# happens because the first is waiting for the second. Deadlock.
#
# == The Solution
#
# The DeadlockDetection middleware tracks which VO keys are held by the
# current call chain and raises immediately when a call would deadlock,
# giving you a clear 409 error instead of a silent hang.
#
# == Running
#
#   cd examples
#   ruby deadlock_detection.rb
#
# Or with Falcon:
#   bundle exec falcon serve --bind http://localhost:9080 -n 1 -c deadlock_detection.rb
#
# Register:
#   restate deployments register http://localhost:9080
#
# Test a normal transfer (works fine):
#   curl localhost:8080/Account/alice/transfer \
#     -H 'content-type: application/json' \
#     -d '{"to_account": "bob", "amount": 50}'
#
# Trigger the deadlock (immediate 409 error):
#   curl localhost:8080/Account/alice/transfer \
#     -H 'content-type: application/json' \
#     -d '{"to_account": "alice", "amount": 50}'
#
# Without the middleware, the self-transfer hangs forever.
# With it, you get an immediate 409 explaining the deadlock.

require 'restate'
require_relative '../lib/restate/middleware/deadlock_detection'

class Account < Restate::VirtualObject
  state :balance, default: 0

  handler def deposit(input)
    amount = input['amount']
    self.balance += amount
    { balance: balance }
  end

  handler def withdraw(input)
    amount = input['amount']
    raise Restate::TerminalError.new('Insufficient funds', status_code: 400) if balance < amount

    self.balance -= amount
    { balance: balance }
  end

  # This handler demonstrates a potential deadlock. If `to_account` is the same
  # as this object's key, the call to Account.call(to_account).deposit(...)
  # would deadlock — we already hold the exclusive lock on this key.
  #
  # The DeadlockDetection middleware catches this and raises immediately.
  handler def transfer(input)
    to_account = input['to_account']
    amount = input['amount']

    raise Restate::TerminalError.new('Insufficient funds', status_code: 400) if balance < amount

    self.balance -= amount

    # If to_account == key, this call targets the same VO key we're holding.
    # Without deadlock detection, it hangs forever.
    # With deadlock detection, it raises DeadlockError immediately.
    Restate.object_call(Account, :deposit, to_account, { 'amount' => amount })

    { balance: balance }
  end

  shared def balance_info
    { balance: balance }
  end
end

# Wire everything together with deadlock detection middleware
endpoint = Restate.endpoint(Account)

# Inbound: detects deadlocks when a handler is invoked on an already-held VO key
endpoint.use(Restate::Middleware::DeadlockDetection::Inbound)

# Outbound: propagates held-lock info and catches same-service deadlocks early
endpoint.use_outbound(Restate::Middleware::DeadlockDetection::Outbound)

run endpoint.app
