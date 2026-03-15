# typed: true
# frozen_string_literal: true

#
# Example: Virtual Objects
#
# A VirtualObject has a key and durable K/V state scoped to that key.
# Exclusive handlers run with mutual exclusion per key, so state
# updates are safe without external locking. Shared handlers allow
# concurrent reads.
#
# Features:
#   - ctx.get / ctx.set / ctx.clear   — K/V state operations
#   - ctx.state_keys / ctx.clear_all  — enumerate or wipe all state
#   - handler  (exclusive)            — one invocation at a time per key
#   - shared   (concurrent)           — many readers, no writes
#
# Try it:
#   curl localhost:8080/Counter/add    -H 'content-type: application/json' -d '3'
#   curl localhost:8080/Counter/add    -H 'content-type: application/json' -d '2'
#   curl localhost:8080/Counter/get    -H 'content-type: application/json' -d 'null'
#   curl localhost:8080/Counter/reset  -H 'content-type: application/json' -d 'null'

require 'restate'

class Counter < Restate::VirtualObject
  # Exclusive handler — only one runs at a time per key.
  # Safe to read-modify-write without races.
  handler def add(addend)
    increment_by(addend)
  end

  private

  # Demonstrates Restate.current_object_context — access the handler context
  # from any method without threading `ctx` through every call.
  def increment_by(addend)
    ctx = Restate.current_object_context
    current = ctx.get('count') || 0
    updated = current + addend
    ctx.set('count', updated)
    updated
  end

  public

  # Shared handler — concurrent access allowed.
  # Great for reads that don't mutate state.
  shared def get
    ctx = Restate.current_shared_context
    ctx.get('count') || 0
  end

  # Exclusive handler — clears a single state key.
  handler def reset
    ctx = Restate.current_object_context
    ctx.clear('count')
    'counter reset'
  end

  # Exclusive handler — lists all keys then wipes everything.
  handler def reset_all
    ctx = Restate.current_object_context
    keys = ctx.state_keys
    ctx.clear_all
    { 'cleared_keys' => keys }
  end
end
