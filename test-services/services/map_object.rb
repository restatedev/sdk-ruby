# typed: false
# frozen_string_literal: true

require 'restate'

class MapObject < Restate::VirtualObject
  handler def set(entry)
    Restate.set(entry['key'], entry['value'])
    nil
  end

  handler def get(key)
    Restate.get(key) || ''
  end

  handler def clearAll # rubocop:disable Naming/MethodName
    entries = []
    Restate.state_keys.each do |key|
      value = Restate.get(key)
      entries << { 'key' => key, 'value' => value }
      Restate.clear(key)
    end
    entries
  end
end
