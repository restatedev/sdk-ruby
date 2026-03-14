# typed: false
# frozen_string_literal: true

require 'restate'

BLOCK_AND_WAIT_WORKFLOW = Restate.workflow('BlockAndWaitWorkflow')

BLOCK_AND_WAIT_WORKFLOW.main('run') do |ctx, input|
  ctx.set('my-state', input)
  output = ctx.promise('durable-promise')

  peek = ctx.peek_promise('durable-promise')
  raise Restate::TerminalError, 'Durable promise should be completed' if peek.nil?

  output
end

BLOCK_AND_WAIT_WORKFLOW.handler('unblock') do |ctx, output|
  ctx.resolve_promise('durable-promise', output)
  nil
end

BLOCK_AND_WAIT_WORKFLOW.handler('getState') do |ctx, _output|
  ctx.get('my-state')
end
