# typed: false
# frozen_string_literal: true

require 'restate'

class AwakeableHolder < Restate::VirtualObject
  handler def hold(ctx, id) # rubocop:disable Naming/MethodParameterName
    ctx.set('id', id)
    nil
  end

  handler def hasAwakeable(ctx) # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    result = ctx.get('id')
    !result.nil?
  end

  handler def unlock(ctx, payload)
    id = ctx.get('id')
    raise Restate::TerminalError, 'No awakeable is registered' if id.nil?

    ctx.resolve_awakeable(id, payload)
    nil
  end
end
