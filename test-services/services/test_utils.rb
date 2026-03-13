# typed: false
# frozen_string_literal: true

require 'restate'

TEST_UTILS = Restate.service('TestUtilsService')

TEST_UTILS.handler('echo') do |_ctx, input|
  input
end

TEST_UTILS.handler('uppercaseEcho') do |_ctx, input|
  input.upcase
end

TEST_UTILS.handler('echoHeaders') do |ctx|
  ctx.request.headers.to_h
end

TEST_UTILS.handler('rawEcho',
                   accept: '*/*',
                   content_type: 'application/octet-stream',
                   input_serde: Restate::BytesSerde,
                   output_serde: Restate::BytesSerde) do |_ctx, input|
  input
end

TEST_UTILS.handler('countExecutedSideEffects') do |ctx, increments|
  invoked_side_effects = 0
  increments.times do
    ctx.run('count') do
      invoked_side_effects += 1
    end
  end
  invoked_side_effects
end

TEST_UTILS.handler('sleepConcurrently') do |ctx, millis_list|
  handles = millis_list.map { |ms| ctx.create_sleep(ms / 1000.0) }
  handles.each { |h| ctx.resolve_handle(h) }
  nil
end
