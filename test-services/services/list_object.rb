# typed: false
# frozen_string_literal: true

require 'restate'

class ListObject < Restate::VirtualObject
  handler def append(value)
    ctx = Restate.current_object_context
    list = ctx.get('list') || []
    ctx.set('list', list + [value])
    nil
  end

  handler def get
    ctx = Restate.current_object_context
    ctx.get('list') || []
  end

  handler def clear
    ctx = Restate.current_object_context
    result = ctx.get('list') || []
    ctx.clear('list')
    result
  end
end
