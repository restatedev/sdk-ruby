# typed: false
# frozen_string_literal: true

require 'restate'

class ListObject < Restate::VirtualObject
  handler def append(ctx, value)
    list = ctx.get('list') || []
    ctx.set('list', list + [value])
    nil
  end

  handler def get(ctx)
    ctx.get('list') || []
  end

  handler def clear(ctx)
    result = ctx.get('list') || []
    ctx.clear('list')
    result
  end
end
