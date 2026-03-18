# typed: false
# frozen_string_literal: true

require 'json'
require 'restate'

def create_future_for_command(cmd) # rubocop:disable Metrics/MethodLength
  ctx = Restate.current_object_context
  case cmd['type']
  when 'createAwakeable'
    awk_id, future = ctx.awakeable
    ctx.set("awk-#{cmd['awakeableKey']}", awk_id)
    [:awakeable, future]
  when 'sleep'
    [:sleep, ctx.sleep(cmd['timeoutMillis'] / 1000.0)]
  when 'runThrowTerminalException'
    reason = cmd['reason']
    future = ctx.run('run should fail command') do
      raise Restate::TerminalError, reason
    end
    [:run, future]
  end
end

def await_future_result(type, future)
  # DurableFuture#await already deserializes via JsonSerde, so no extra JSON.parse needed.
  # For sleep futures, the raw value is nil/empty — return a marker string.
  return 'sleep' if type == :sleep

  future.await
end

class VirtualObjectCommandInterpreter < Restate::VirtualObject
  shared def getResults(ctx) # rubocop:disable Naming/MethodName
    ctx.get('results') || []
  end

  shared def hasAwakeable(ctx, awk_key) # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    awk_id = ctx.get("awk-#{awk_key}")
    !awk_id.nil?
  end

  shared def resolveAwakeable(ctx, req) # rubocop:disable Naming/MethodName
    awk_id = ctx.get("awk-#{req['awakeableKey']}")
    raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

    ctx.resolve_awakeable(awk_id, req['value'])
    nil
  end

  shared def rejectAwakeable(ctx, req) # rubocop:disable Naming/MethodName
    awk_id = ctx.get("awk-#{req['awakeableKey']}")
    raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

    ctx.reject_awakeable(awk_id, req['reason'])
    nil
  end

  handler def interpretCommands(ctx, req) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Naming/MethodName,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    result = ''

    req['commands'].each do |cmd| # rubocop:disable Metrics/BlockLength
      case cmd['type']
      when 'awaitAwakeableOrTimeout'
        awk_id, awk_future = ctx.awakeable
        ctx.set("awk-#{cmd['awakeableKey']}", awk_id)
        sleep_future = ctx.sleep(cmd['timeoutMillis'] / 1000.0)

        completed, = ctx.wait_any(awk_future, sleep_future)

        if completed.include?(awk_future)
          result = awk_future.await
        else
          sleep_future.await
          raise Restate::TerminalError, 'await-timeout'
        end

      when 'resolveAwakeable'
        awk_id = ctx.get("awk-#{cmd['awakeableKey']}")
        raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

        ctx.resolve_awakeable(awk_id, cmd['value'])
        result = ''

      when 'rejectAwakeable'
        awk_id = ctx.get("awk-#{cmd['awakeableKey']}")
        raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

        ctx.reject_awakeable(awk_id, cmd['reason'])
        result = ''

      when 'getEnvVariable'
        env_name = cmd['envName']
        result = ctx.run('get_env') { ENV.fetch(env_name, '') }.await

      when 'awaitOne'
        type, future = create_future_for_command(cmd['command'])
        result = await_future_result(type, future)

      when 'awaitAny'
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        completed, = ctx.wait_any(*futures)
        winner = completed.first
        idx = entries.index { |_, f| f == winner }
        type, future = entries[idx]
        result = await_future_result(type, future)

      when 'awaitAnySuccessful'
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        remaining = entries.dup
        found = false
        until remaining.empty?
          futures = remaining.map(&:last)
          completed, = ctx.wait_any(*futures)
          winner = completed.first
          idx = remaining.index { |_, f| f == winner }
          type, future = remaining[idx]
          begin
            result = await_future_result(type, future)
            found = true
            break
          rescue Restate::TerminalError
            remaining.delete_at(idx)
          end
        end
        raise Restate::TerminalError, 'All commands failed' unless found
      end

      last_results = ctx.get('results') || []
      last_results << result
      ctx.set('results', last_results)
    end

    result
  end
end
