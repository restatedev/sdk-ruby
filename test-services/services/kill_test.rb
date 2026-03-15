# typed: false
# frozen_string_literal: true

require 'restate'

class KillTestRunner < Restate::VirtualObject
  handler def startCallTree # rubocop:disable Naming/MethodName
    ctx = Restate.current_object_context
    ctx.object_call(KillTestSingleton, :recursiveCall, ctx.key, nil).await
    nil
  end
end

class KillTestSingleton < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def recursiveCall # rubocop:disable Naming/MethodName
    ctx = Restate.current_object_context
    id, awk_future = ctx.awakeable
    ctx.object_send('AwakeableHolder', 'hold', ctx.key, id)
    awk_future.await

    ctx.object_call('KillTestSingleton', 'recursiveCall', ctx.key, nil).await
    nil
  end

  handler def isUnlocked # rubocop:disable Naming/MethodName
    nil
  end
end
