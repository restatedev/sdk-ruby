# typed: false
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
#   - handler  (exclusive)      — one invocation at a time per key
#   - shared   (concurrent)     — many readers, no writes
#
# You can also use ctx.get / ctx.set / ctx.clear directly.
#
# Try it:
#   curl localhost:8080/Counter/add    -H 'content-type: application/json' -d '3'
#   curl localhost:8080/Counter/add    -H 'content-type: application/json' -d '2'
#   curl localhost:8080/Counter/get    -H 'content-type: application/json' -d 'null'
#   curl localhost:8080/Counter/reset  -H 'content-type: application/json' -d 'null'

require 'restate'

class Counter < Restate::VirtualObject
  # Declare durable state with a default value.
  # Generates: count (getter), count= (setter), clear_count (clear).
  state :count, default: 0

  # Exclusive handler — only one runs at a time per key.
  # Safe to read-modify-write without races.
  # @param ctx [Restate::ObjectContext]
  handler def add(_ctx, addend)
    self.count += addend
  end

  # Shared handler — concurrent access allowed.
  # Great for reads that don't mutate state.
  # @param ctx [Restate::ObjectSharedContext]
  shared def get(_ctx)
    count
  end

  # Exclusive handler — clears a single state key.
  # @param ctx [Restate::ObjectContext]
  handler def reset(_ctx)
    clear_count
    'counter reset'
  end

  # Exclusive handler — lists all keys then wipes everything.
  # You can still use ctx.get/ctx.set/ctx.clear directly.
  # @param ctx [Restate::ObjectContext]
  handler def reset_all(ctx)
    keys = ctx.state_keys
    ctx.clear_all
    { 'cleared_keys' => keys }
  end
end
