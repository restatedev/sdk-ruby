# typed: false
# frozen_string_literal: true

require 'restate'

class ListObject < Restate::VirtualObject
  handler def append(value)
    list = Restate.get('list') || []
    Restate.set('list', list + [value])
    nil
  end

  handler def get
    Restate.get('list') || []
  end

  handler def clear
    result = Restate.get('list') || []
    Restate.clear('list')
    result
  end
end
