# typed: false
# frozen_string_literal: true

require 'restate'

class Failing < Restate::VirtualObject
  handler def terminallyFailingCall(_ctx, msg) # rubocop:disable Naming/MethodName
    raise Restate::TerminalError, msg
  end

  handler def callTerminallyFailingCall(ctx, msg) # rubocop:disable Naming/MethodName
    ctx.object_call('Failing', 'terminallyFailingCall', 'random-583e1bf2', msg).await
    raise 'Should not reach here'
  end

  $failures = 0 # rubocop:disable Style/GlobalVars

  handler def failingCallWithEventualSuccess(_ctx) # rubocop:disable Naming/MethodName
    $failures += 1 # rubocop:disable Style/GlobalVars
    raise "Failed at attempt: #{$failures}" unless $failures >= 4 # rubocop:disable Style/GlobalVars

    $failures = 0 # rubocop:disable Style/GlobalVars
    4
  end

  handler def terminallyFailingSideEffect(ctx, error_message) # rubocop:disable Naming/MethodName
    ctx.run('sideEffect') do
      raise Restate::TerminalError, error_message
    end
    raise 'Should not reach here'
  end

  $eventual_success_side_effects = 0 # rubocop:disable Style/GlobalVars

  handler def sideEffectSucceedsAfterGivenAttempts(ctx, minimum_attempts) # rubocop:disable Naming/MethodName,Metrics/MethodLength
    retry_policy = Restate::RunRetryPolicy.new(
      max_attempts: minimum_attempts + 1,
      initial_interval: 1,
      interval_factor: 1.0
    )
    ctx.run('sideEffect', retry_policy: retry_policy) do
      $eventual_success_side_effects += 1 # rubocop:disable Style/GlobalVars
      unless $eventual_success_side_effects >= minimum_attempts # rubocop:disable Style/GlobalVars
        raise "Failed at attempt: #{$eventual_success_side_effects}" # rubocop:disable Style/GlobalVars
      end

      $eventual_success_side_effects # rubocop:disable Style/GlobalVars
    end
  end

  $eventual_failure_side_effects = 0 # rubocop:disable Style/GlobalVars

  handler def sideEffectFailsAfterGivenAttempts(ctx, retry_policy_max_retry_count) # rubocop:disable Naming/MethodName,Metrics/MethodLength
    retry_policy = Restate::RunRetryPolicy.new(
      max_attempts: retry_policy_max_retry_count,
      initial_interval: 1,
      interval_factor: 1.0
    )
    begin
      ctx.run('sideEffect', retry_policy: retry_policy) do
        $eventual_failure_side_effects += 1 # rubocop:disable Style/GlobalVars
        raise "Failed at attempt: #{$eventual_failure_side_effects}" # rubocop:disable Style/GlobalVars
      end
      raise 'Side effect did not fail.'
    rescue Restate::TerminalError
      $eventual_failure_side_effects # rubocop:disable Style/GlobalVars
    end
  end
end
