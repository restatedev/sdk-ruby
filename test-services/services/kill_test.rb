# frozen_string_literal: true

require 'restate'

class KillTestRunner < Restate::VirtualObject
  handler def startCallTree # rubocop:disable Naming/MethodName
    KillTestSingleton.call(Restate.key).recursiveCall.await
    nil
  end
end

class KillTestSingleton < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def recursiveCall # rubocop:disable Naming/MethodName
    id, awk_future = Restate.awakeable
    AwakeableHolder.send!(Restate.key).hold(id)
    awk_future.await

    KillTestSingleton.call(Restate.key).recursiveCall.await
    nil
  end

  handler def isUnlocked # rubocop:disable Naming/MethodName
    nil
  end
end
