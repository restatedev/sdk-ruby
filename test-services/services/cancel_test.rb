# typed: false
# frozen_string_literal: true

require 'restate'

class CancelTestRunner < Restate::VirtualObject
  handler def startTest(ctx, op) # rubocop:disable Naming/MethodName,Naming/MethodParameterName
    begin
      ctx.object_call(CancelTestBlockingService, :block, ctx.key, op).await
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

  handler def isUnlocked(_ctx) # rubocop:disable Naming/MethodName
    nil
  end
end
