# typed: false
# frozen_string_literal: true

require 'restate'

class MapObject < Restate::VirtualObject
  handler def set(ctx, entry)
    ctx.set(entry['key'], entry['value'])
    nil
  end

  handler def get(ctx, key)
    ctx.get(key) || ''
  end

  handler def clearAll(ctx) # rubocop:disable Naming/MethodName
    entries = []
    ctx.state_keys.each do |key|
      value = ctx.get(key)
      entries << { 'key' => key, 'value' => value }
      ctx.clear(key)
    end
    entries
  end
end
