# typed: false
# frozen_string_literal: true

require 'restate'

$invoke_counts = {} # rubocop:disable Style/GlobalVars

def do_left_action # rubocop:disable Naming/PredicateMethod
  ctx = Restate.current_object_context
  count_key = ctx.key
  $invoke_counts[count_key] = ($invoke_counts[count_key] || 0) + 1 # rubocop:disable Style/GlobalVars
  $invoke_counts[count_key].odd? # rubocop:disable Style/GlobalVars
end

def increment_counter
  ctx = Restate.current_object_context
  ctx.object_send(Counter, :add, ctx.key, 1)
end

class NonDeterministic < Restate::VirtualObject
  handler def setDifferentKey(ctx) # rubocop:disable Naming/MethodName
    if do_left_action
      ctx.set('a', 'my-state')
    else
      ctx.set('b', 'my-state')
    end
    ctx.sleep(0.1).await
    increment_counter
    nil
  end

  handler def backgroundInvokeWithDifferentTargets(ctx) # rubocop:disable Naming/MethodName
    if do_left_action
      ctx.object_send('Counter', 'get', 'abc', nil)
    else
      ctx.object_send('Counter', 'reset', 'abc', nil)
    end
    ctx.sleep(0.1).await
    increment_counter
    nil
  end

  handler def callDifferentMethod(ctx) # rubocop:disable Naming/MethodName
    if do_left_action
      ctx.object_call('Counter', 'get', 'abc', nil).await
    else
      ctx.object_call('Counter', 'reset', 'abc', nil).await
    end
    ctx.sleep(0.1).await
    increment_counter
    nil
  end

  handler def eitherSleepOrCall(ctx) # rubocop:disable Naming/MethodName
    if do_left_action
      ctx.sleep(0.1).await
    else
      ctx.object_call('Counter', 'get', 'abc', nil).await
    end
    ctx.sleep(0.1).await
    increment_counter
    nil
  end
end
