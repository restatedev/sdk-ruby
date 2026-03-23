# frozen_string_literal: true

require 'restate'

class KillTestRunner < Restate::VirtualObject
  handler def startCallTree # rubocop:disable Naming/MethodName
    Restate.object_call(KillTestSingleton, :recursiveCall, Restate.key, nil).await
    nil
  end
end

class KillTestSingleton < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def recursiveCall # rubocop:disable Naming/MethodName
    id, awk_future = Restate.awakeable
    Restate.object_send('AwakeableHolder', 'hold', Restate.key, id)
    awk_future.await

    Restate.object_call('KillTestSingleton', 'recursiveCall', Restate.key, nil).await
    nil
  end

  handler def isUnlocked # rubocop:disable Naming/MethodName
    nil
  end
end
