# frozen_string_literal: true

require 'restate'

$invoke_counts = {} # rubocop:disable Style/GlobalVars

def do_left_action # rubocop:disable Naming/PredicateMethod
  count_key = Restate.key
  $invoke_counts[count_key] = ($invoke_counts[count_key] || 0) + 1 # rubocop:disable Style/GlobalVars
  $invoke_counts[count_key].odd? # rubocop:disable Style/GlobalVars
end

def increment_counter
  Counter.send!(Restate.key).add(1)
end

class NonDeterministic < Restate::VirtualObject
  handler def setDifferentKey # rubocop:disable Naming/MethodName
    if do_left_action
      Restate.set('a', 'my-state')
    else
      Restate.set('b', 'my-state')
    end
    Restate.sleep(0.1).await
    increment_counter
    nil
  end

  handler def backgroundInvokeWithDifferentTargets # rubocop:disable Naming/MethodName
    if do_left_action
      Restate.object_send('Counter', 'get', 'abc', nil)
    else
      Restate.object_send('Counter', 'reset', 'abc', nil)
    end
    Restate.sleep(0.1).await
    increment_counter
    nil
  end

  handler def callDifferentMethod # rubocop:disable Naming/MethodName
    if do_left_action
      Restate.object_call('Counter', 'get', 'abc', nil).await
    else
      Restate.object_call('Counter', 'reset', 'abc', nil).await
    end
    Restate.sleep(0.1).await
    increment_counter
    nil
  end

  handler def eitherSleepOrCall # rubocop:disable Naming/MethodName
    if do_left_action
      Restate.sleep(0.1).await
    else
      Restate.object_call('Counter', 'get', 'abc', nil).await
    end
    Restate.sleep(0.1).await
    increment_counter
    nil
  end
end
