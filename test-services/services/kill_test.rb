# typed: false
# frozen_string_literal: true

require 'restate'

class KillTestRunner < Restate::VirtualObject
  handler def startCallTree(ctx) # rubocop:disable Naming/MethodName
    ctx.object_call(KillTestSingleton, :recursiveCall, ctx.key, nil).await
    nil
  end
end

class KillTestSingleton < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def recursiveCall(ctx) # rubocop:disable Naming/MethodName
    id, awk_future = ctx.awakeable
    ctx.object_send('AwakeableHolder', 'hold', ctx.key, id)
    awk_future.await

    ctx.object_call('KillTestSingleton', 'recursiveCall', ctx.key, nil).await
    nil
  end

  handler def isUnlocked(_ctx) # rubocop:disable Naming/MethodName
    nil
  end
end
