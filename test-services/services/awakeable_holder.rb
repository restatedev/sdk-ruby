# typed: false
# frozen_string_literal: true

require 'restate'

class AwakeableHolder < Restate::VirtualObject
  handler def hold(id) # rubocop:disable Naming/MethodParameterName
    ctx = Restate.current_object_context
    ctx.set('id', id)
    nil
  end

  handler def hasAwakeable # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    ctx = Restate.current_object_context
    result = ctx.get('id')
    !result.nil?
  end

  handler def unlock(payload)
    ctx = Restate.current_object_context
    id = ctx.get('id')
    raise Restate::TerminalError, 'No awakeable is registered' if id.nil?

    ctx.resolve_awakeable(id, payload)
    nil
  end
end
