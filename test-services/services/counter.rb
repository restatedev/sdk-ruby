# typed: false
# frozen_string_literal: true

require 'restate'

class Counter < Restate::VirtualObject
  handler def reset(ctx)
    ctx.clear('counter')
    nil
  end

  handler def get(ctx)
    ctx.get('counter') || 0
  end

  handler def add(ctx, addend)
    old_value = ctx.get('counter') || 0
    new_value = old_value + addend
    ctx.set('counter', new_value)
    { 'oldValue' => old_value, 'newValue' => new_value }
  end

  handler def addThenFail(ctx, addend) # rubocop:disable Naming/MethodName
    old_value = ctx.get('counter') || 0
    new_value = old_value + addend
    ctx.set('counter', new_value)
    raise Restate::TerminalError, ctx.key
  end
end
