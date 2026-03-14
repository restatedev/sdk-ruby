# typed: false
# frozen_string_literal: true

require 'restate'

class TestUtilsService < Restate::Service
  handler def echo(_ctx, input)
    input
  end

  handler def uppercaseEcho(_ctx, input) # rubocop:disable Naming/MethodName
    input.upcase
  end

  handler def echoHeaders(ctx) # rubocop:disable Naming/MethodName
    ctx.request.headers.to_h
  end

  handler :rawEcho, accept: '*/*', content_type: 'application/octet-stream',
                    input_serde: Restate::BytesSerde, output_serde: Restate::BytesSerde
  def rawEcho(_ctx, input) # rubocop:disable Naming/MethodName
    input
  end

  handler def countExecutedSideEffects(ctx, increments) # rubocop:disable Naming/MethodName
    invoked_side_effects = 0
    increments.times do
      ctx.run('count') do
        invoked_side_effects += 1
      end
    end
    invoked_side_effects
  end

  handler def cancelInvocation(ctx, invocation_id) # rubocop:disable Naming/MethodName
    ctx.cancel_invocation(invocation_id)
    nil
  end

  handler def sleepConcurrently(ctx, millis_list) # rubocop:disable Naming/MethodName
    futures = millis_list.map { |ms| ctx.sleep(ms / 1000.0) }
    futures.each(&:await)
    nil
  end
end
