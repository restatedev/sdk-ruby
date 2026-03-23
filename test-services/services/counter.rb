# frozen_string_literal: true

require 'restate'

class Counter < Restate::VirtualObject
  handler def reset
    Restate.clear('counter')
    nil
  end

  handler def get
    Restate.get('counter') || 0
  end

  handler def add(addend)
    old_value = Restate.get('counter') || 0
    new_value = old_value + addend
    Restate.set('counter', new_value)
    { 'oldValue' => old_value, 'newValue' => new_value }
  end

  handler def addThenFail(addend) # rubocop:disable Naming/MethodName
    old_value = Restate.get('counter') || 0
    new_value = old_value + addend
    Restate.set('counter', new_value)
    raise Restate::TerminalError, Restate.key
  end
end
