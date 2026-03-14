# typed: false
# frozen_string_literal: true

require 'restate'

class BlockAndWaitWorkflow < Restate::Workflow
  main def run(ctx, input)
    ctx.set('my-state', input)
    output = ctx.promise('durable-promise')

    peek = ctx.peek_promise('durable-promise')
    raise Restate::TerminalError, 'Durable promise should be completed' if peek.nil?

    output
  end

  handler def unblock(ctx, output)
    ctx.resolve_promise('durable-promise', output)
    nil
  end

  handler def getState(ctx, _output) # rubocop:disable Naming/MethodName
    ctx.get('my-state')
  end
end
