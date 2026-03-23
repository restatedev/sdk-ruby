# frozen_string_literal: true

require 'restate'

class BlockAndWaitWorkflow < Restate::Workflow
  main def run(input)
    Restate.set('my-state', input)
    output = Restate.promise('durable-promise')

    peek = Restate.peek_promise('durable-promise')
    raise Restate::TerminalError, 'Durable promise should be completed' if peek.nil?

    output
  end

  handler def unblock(output)
    Restate.resolve_promise('durable-promise', output)
    nil
  end

  handler def getState(_output) # rubocop:disable Naming/MethodName
    Restate.get('my-state')
  end
end
