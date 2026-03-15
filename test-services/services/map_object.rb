# typed: false
# frozen_string_literal: true

require 'restate'

class MapObject < Restate::VirtualObject
  handler def set(entry)
    ctx = Restate.current_object_context
    ctx.set(entry['key'], entry['value'])
    nil
  end

  handler def get(key)
    ctx = Restate.current_object_context
    ctx.get(key) || ''
  end

  handler def clearAll # rubocop:disable Naming/MethodName
    ctx = Restate.current_object_context
    entries = []
    ctx.state_keys.each do |key|
      value = ctx.get(key)
      entries << { 'key' => key, 'value' => value }
      ctx.clear(key)
    end
    entries
  end
end
