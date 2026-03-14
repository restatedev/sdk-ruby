# typed: false
# frozen_string_literal: true

require 'restate'

KILL_TEST_RUNNER = Restate.virtual_object('KillTestRunner')

KILL_TEST_RUNNER.handler('startCallTree') do |ctx|
  ctx.object_call('KillTestSingleton', 'recursiveCall', ctx.key, nil)
  nil
end

KILL_TEST_SINGLETON = Restate.virtual_object('KillTestSingleton')

KILL_TEST_SINGLETON.handler('recursiveCall') do |ctx|
  id, handle = ctx.create_awakeable
  ctx.object_send('AwakeableHolder', 'hold', ctx.key, id)
  ctx.resolve_handle(handle)

  ctx.object_call('KillTestSingleton', 'recursiveCall', ctx.key, nil)
  nil
end

KILL_TEST_SINGLETON.handler('isUnlocked') do |_ctx|
  nil
end
