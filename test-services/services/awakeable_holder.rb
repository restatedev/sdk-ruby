# frozen_string_literal: true

require 'restate'

class AwakeableHolder < Restate::VirtualObject
  handler def hold(id) # rubocop:disable Naming/MethodParameterName
    Restate.set('id', id)
    nil
  end

  handler def hasAwakeable # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    result = Restate.get('id')
    !result.nil?
  end

  handler def unlock(payload)
    id = Restate.get('id')
    raise Restate::TerminalError, 'No awakeable is registered' if id.nil?

    Restate.resolve_awakeable(id, payload)
    nil
  end
end
