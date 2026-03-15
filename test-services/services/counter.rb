# typed: false
# frozen_string_literal: true

require 'restate'

class Counter < Restate::VirtualObject
  handler def reset
    ctx = Restate.current_object_context
    ctx.clear('counter')
    nil
  end

  handler def get
    ctx = Restate.current_object_context
    ctx.get('counter') || 0
  end

  handler def add(addend)
    ctx = Restate.current_object_context
    old_value = ctx.get('counter') || 0
    new_value = old_value + addend
    ctx.set('counter', new_value)
    { 'oldValue' => old_value, 'newValue' => new_value }
  end

  handler def addThenFail(addend) # rubocop:disable Naming/MethodName
    ctx = Restate.current_object_context
    old_value = ctx.get('counter') || 0
    new_value = old_value + addend
    ctx.set('counter', new_value)
    raise Restate::TerminalError, ctx.key
  end
end
