# typed: false
# frozen_string_literal: true

require 'restate'

FAILING = Restate.virtual_object('Failing')

FAILING.handler('terminallyFailingCall') do |_ctx, msg|
  raise Restate::TerminalError, msg
end

FAILING.handler('callTerminallyFailingCall') do |ctx, msg|
  ctx.object_call('Failing', 'terminallyFailingCall', 'random-583e1bf2', msg)
  raise 'Should not reach here'
end

$failures = 0 # rubocop:disable Style/GlobalVars

FAILING.handler('failingCallWithEventualSuccess') do |_ctx|
  $failures += 1 # rubocop:disable Style/GlobalVars
  raise "Failed at attempt: #{$failures}" unless $failures >= 4 # rubocop:disable Style/GlobalVars

  $failures = 0 # rubocop:disable Style/GlobalVars
  4
end

FAILING.handler('terminallyFailingSideEffect') do |ctx, error_message|
  ctx.run('sideEffect') do
    raise Restate::TerminalError, error_message
  end
  raise 'Should not reach here'
end

$eventual_success_side_effects = 0 # rubocop:disable Style/GlobalVars

FAILING.handler('sideEffectSucceedsAfterGivenAttempts') do |ctx, minimum_attempts|
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

FAILING.handler('sideEffectFailsAfterGivenAttempts') do |ctx, retry_policy_max_retry_count|
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
