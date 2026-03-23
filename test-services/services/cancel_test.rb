# frozen_string_literal: true

require 'restate'

class CancelTestRunner < Restate::VirtualObject
  handler def startTest(op) # rubocop:disable Naming/MethodName,Naming/MethodParameterName
    begin
      CancelTestBlockingService.call(Restate.key).block(op).await
    rescue Restate::TerminalError => e
      raise e unless e.status_code == 409

      Restate.set('state', true)
    end
    nil
  end

  handler def verifyTest # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    state = Restate.get('state')
    state == true
  end
end

class CancelTestBlockingService < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  handler def block(op) # rubocop:disable Metrics/MethodLength,Naming/MethodParameterName
    id, awk_future = Restate.awakeable
    AwakeableHolder.call(Restate.key).hold(id).await
    awk_future.await

    case op
    when 'CALL'
      CancelTestBlockingService.call(Restate.key).block(op).await
    when 'SLEEP'
      Restate.sleep(1_024 * 24 * 60 * 60).await
    when 'AWAKEABLE'
      _id2, awk_future2 = Restate.awakeable
      awk_future2.await
    end
    nil
  end

  handler def isUnlocked # rubocop:disable Naming/MethodName
    nil
  end
end
