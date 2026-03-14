# typed: false
# frozen_string_literal: true

require 'restate'

class CancelTestRunner < Restate::VirtualObject
  handler def startTest(ctx, op) # rubocop:disable Naming/MethodName,Naming/MethodParameterName
    begin
      ctx.object_call(CancelTestBlockingService, :block, ctx.key, op)
    rescue Restate::TerminalError => e
      raise e unless e.status_code == 409

      ctx.set('state', true)
    end
    nil
  end

  handler def verifyTest(ctx) # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    state = ctx.get('state')
    state == true
  end
end

class CancelTestBlockingService < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def block(ctx, op) # rubocop:disable Metrics/MethodLength,Naming/MethodParameterName
    id, handle = ctx.create_awakeable
    ctx.object_call('AwakeableHolder', 'hold', ctx.key, id)
    ctx.resolve_handle(handle)

    case op
    when 'CALL'
      ctx.object_call('CancelTestBlockingService', 'block', ctx.key, op)
    when 'SLEEP'
      ctx.sleep(1_024 * 24 * 60 * 60)
    when 'AWAKEABLE'
      _id2, handle2 = ctx.create_awakeable
      ctx.resolve_handle(handle2)
    end
    nil
  end

  handler def isUnlocked(_ctx) # rubocop:disable Naming/MethodName
    nil
  end
end
