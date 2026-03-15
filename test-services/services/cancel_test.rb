# typed: false
# frozen_string_literal: true

require 'restate'

class CancelTestRunner < Restate::VirtualObject
  handler def startTest(op) # rubocop:disable Naming/MethodName,Naming/MethodParameterName
    ctx = Restate.current_object_context
    begin
      ctx.object_call(CancelTestBlockingService, :block, ctx.key, op).await
    rescue Restate::TerminalError => e
      raise e unless e.status_code == 409

      ctx.set('state', true)
    end
    nil
  end

  handler def verifyTest # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    ctx = Restate.current_object_context
    state = ctx.get('state')
    state == true
  end
end

class CancelTestBlockingService < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def block(op) # rubocop:disable Metrics/MethodLength,Naming/MethodParameterName
    ctx = Restate.current_object_context
    id, awk_future = ctx.awakeable
    ctx.object_call('AwakeableHolder', 'hold', ctx.key, id).await
    awk_future.await

    case op
    when 'CALL'
      ctx.object_call('CancelTestBlockingService', 'block', ctx.key, op).await
    when 'SLEEP'
      ctx.sleep(1_024 * 24 * 60 * 60).await
    when 'AWAKEABLE'
      _id2, awk_future2 = ctx.awakeable
      awk_future2.await
    end
    nil
  end

  handler def isUnlocked # rubocop:disable Naming/MethodName
    nil
  end
end
