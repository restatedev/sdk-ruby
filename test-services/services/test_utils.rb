# frozen_string_literal: true

require 'restate'

class TestUtilsService < Restate::Service
  handler def echo(input)
    input
  end

  handler def uppercaseEcho(input) # rubocop:disable Naming/MethodName
    input.upcase
  end

  handler def echoHeaders # rubocop:disable Naming/MethodName
    Restate.request.headers.to_h
  end

  handler :rawEcho, accept: '*/*', content_type: 'application/octet-stream',
                    input: Restate::BytesSerde, output: Restate::BytesSerde
  def rawEcho(input) # rubocop:disable Naming/MethodName
    input
  end

  handler def countExecutedSideEffects(increments) # rubocop:disable Naming/MethodName
    invoked_side_effects = 0
    increments.times do
      (Restate.run('count') do
        invoked_side_effects += 1
      end).await
    end
    invoked_side_effects
  end

  handler def cancelInvocation(invocation_id) # rubocop:disable Naming/MethodName
    Restate.cancel_invocation(invocation_id)
    nil
  end

  handler def sleepConcurrently(millis_list) # rubocop:disable Naming/MethodName
    futures = millis_list.map { |ms| Restate.sleep(ms / 1000.0) }
    futures.each(&:await)
    nil
  end
end
