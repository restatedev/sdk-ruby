# typed: false
# frozen_string_literal: true

require 'restate'

class BlockAndWaitWorkflow < Restate::Workflow
  main def run(input)
    ctx = Restate.current_workflow_context
    ctx.set('my-state', input)
    output = ctx.promise('durable-promise')

    peek = ctx.peek_promise('durable-promise')
    raise Restate::TerminalError, 'Durable promise should be completed' if peek.nil?

    output
  end

  handler def unblock(output)
    ctx = Restate.current_shared_workflow_context
    ctx.resolve_promise('durable-promise', output)
    nil
  end

  handler def getState(_output) # rubocop:disable Naming/MethodName
    ctx = Restate.current_shared_workflow_context
    ctx.get('my-state')
  end
end
