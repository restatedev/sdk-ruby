# typed: false
# frozen_string_literal: true

require 'restate'

CANCEL_TEST_RUNNER = Restate.virtual_object('CancelTestRunner')

CANCEL_TEST_RUNNER.handler('startTest') do |ctx, op|
  begin
    ctx.object_call('CancelTestBlockingService', 'block', ctx.key, op)
  rescue Restate::TerminalError => e
    raise e unless e.status_code == 409

    ctx.set('state', true)
  end
  nil
end

CANCEL_TEST_RUNNER.handler('verifyTest') do |ctx|
  state = ctx.get('state')
  state == true
end

CANCEL_TEST_BLOCKING_SERVICE = Restate.virtual_object('CancelTestBlockingService')

CANCEL_TEST_BLOCKING_SERVICE.handler('block') do |ctx, op|
  id, handle = ctx.create_awakeable
  ctx.object_call('AwakeableHolder', 'hold', ctx.key, id)
  ctx.resolve_handle(handle)

  case op
  when 'CALL'
    ctx.object_call('CancelTestBlockingService', 'block', ctx.key, op)
  when 'SLEEP'
    ctx.sleep(1_024 * 24 * 60 * 60)
  when 'AWAKEABLE'
    _id2, handle2 = ctx.create_awakeable
    ctx.resolve_handle(handle2)
  end
  nil
end

CANCEL_TEST_BLOCKING_SERVICE.handler('isUnlocked') do |_ctx|
  nil
end
