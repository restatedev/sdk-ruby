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
#   - state :name, default: val — declarative state with auto accessors
#   - Restate.get / Restate.set — explicit state operations
#   - handler  (exclusive)      — one invocation at a time per key
#   - shared   (concurrent)     — many readers, no writes
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
    current = Restate.get('count') || 0
    updated = current + addend
    Restate.set('count', updated)
    updated
  end

  # Shared handler — concurrent access allowed.
  # Great for reads that don't mutate state.
  shared def get
    Restate.get('count') || 0
  end

  # Exclusive handler — clears a single state key.
  handler def reset
    Restate.clear('count')
    'counter reset'
  end

  # Exclusive handler — lists all keys then wipes everything.
  handler def reset_all
    keys = Restate.state_keys
    Restate.clear_all
    { 'cleared_keys' => keys }
  end
end
