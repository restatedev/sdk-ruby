# frozen_string_literal: true

require 'json'
require 'restate'

# Builds a DurableFuture for the given awaitable command type. The interpreter
# uses this to feed children of combinator commands.
def create_future_for_command(cmd) # rubocop:disable Metrics/MethodLength
  case cmd['type']
  when 'createAwakeable'
    awk_id, future = Restate.awakeable
    Restate.set("awk-#{cmd['awakeableKey']}", awk_id)
    [:awakeable, future]
  when 'createSignal'
    [:signal, Restate.signal(cmd['signalName'])]
  when 'sleep'
    [:sleep, Restate.sleep(cmd['timeoutMillis'] / 1000.0)]
  when 'runReturns'
    value = cmd['value']
    [:run, Restate.run('run returns value command') { value }]
  when 'runThrowTerminalException'
    reason = cmd['reason']
    future = Restate.run('run should fail command') do
      raise Restate::TerminalError, reason
    end
    [:run, future]
  end
end

def await_future_result(type, future)
  # Always block until the future settles. DurableFuture#await deserializes via
  # JsonSerde so no extra JSON.parse is needed. Sleep futures resolve to Void;
  # surface them as the literal 'sleep' marker the test suite expects.
  future.await
  type == :sleep ? 'sleep' : future.await
end

# Helper used by awaitFirstSucceededOrAllFailed to identify the winning future.
# +.await+ on a future that already failed re-raises, so we swallow that here.
def safely_equal(future, value)
  future.await == value
rescue Restate::TerminalError
  false
end

class VirtualObjectCommandInterpreter < Restate::VirtualObject # rubocop:disable Metrics/ClassLength
  shared def getResults # rubocop:disable Naming/MethodName
    Restate.get('results') || []
  end

  shared def hasAwakeable(awk_key) # rubocop:disable Naming/MethodName,Naming/PredicateMethod
    awk_id = Restate.get("awk-#{awk_key}")
    !awk_id.nil?
  end

  shared def resolveAwakeable(req) # rubocop:disable Naming/MethodName
    awk_id = Restate.get("awk-#{req['awakeableKey']}")
    raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

    Restate.resolve_awakeable(awk_id, req['value'])
    nil
  end

  shared def rejectAwakeable(req) # rubocop:disable Naming/MethodName
    awk_id = Restate.get("awk-#{req['awakeableKey']}")
    raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

    Restate.reject_awakeable(awk_id, req['reason'])
    nil
  end

  handler def interpretCommands(req) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize,Naming/MethodName,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    result = ''

    req['commands'].each do |cmd| # rubocop:disable Metrics/BlockLength
      case cmd['type']
      when 'awaitAwakeableOrTimeout'
        awk_id, awk_future = Restate.awakeable
        Restate.set("awk-#{cmd['awakeableKey']}", awk_id)
        sleep_future = Restate.sleep(cmd['timeoutMillis'] / 1000.0)

        completed, = Restate.wait_any(awk_future, sleep_future)

        if completed.include?(awk_future)
          result = awk_future.await
        else
          sleep_future.await
          raise Restate::TerminalError, 'await-timeout'
        end

      when 'resolveAwakeable'
        awk_id = Restate.get("awk-#{cmd['awakeableKey']}")
        raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

        Restate.resolve_awakeable(awk_id, cmd['value'])
        result = ''

      when 'rejectAwakeable'
        awk_id = Restate.get("awk-#{cmd['awakeableKey']}")
        raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

        Restate.reject_awakeable(awk_id, cmd['reason'])
        result = ''

      when 'getEnvVariable'
        env_name = cmd['envName']
        result = Restate.run('get_env') { ENV.fetch(env_name, '') }.await

      when 'awaitOne'
        type, future = create_future_for_command(cmd['command'])
        result = await_future_result(type, future)

      when 'awaitAny'
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        completed, = Restate.wait_any(*futures)
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
          completed, = Restate.wait_any(*futures)
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

      when 'awaitFirstCompleted'
        # JS Promise.race semantics — first to settle (success or failure).
        # Uses the cooperative-suspension AllCompleted variant via Restate.race.
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        Restate.wait_any(*futures) # ensure at least one is ready
        winner = futures.find(&:completed?)
        idx = futures.index(winner)
        type, future = entries[idx]
        result = await_future_result(type, future)

      when 'awaitFirstSucceededOrAllFailed'
        # JS Promise.any semantics. The shared-core variant collects failures
        # and returns when one succeeds or all have failed. The interpreter
        # cares about the winning value; the sleep awaitable resolves to nil,
        # so we substitute the 'sleep' marker when that's what won.
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        winning_value = Restate.any(*futures)
        winning_type = entries.zip(futures)
                              .find { |(_t, _f), fut| fut.completed? && safely_equal(fut, winning_value) }
                              &.first
                              &.first
        result = winning_type == :sleep ? 'sleep' : winning_value

      when 'awaitAllCompleted'
        # JS Promise.allSettled semantics — wait for every future and join the
        # per-future outcome strings with '|'. Each entry is tagged 'ok:' or
        # 'err:' so the assertions can distinguish successes from failures.
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        Restate.all_settled(*futures)
        parts = entries.map do |type, future|
          "ok:#{await_future_result(type, future)}"
        rescue Restate::TerminalError => e
          "err:#{e.message}"
        end
        result = parts.join('|')

      when 'awaitAllSucceededOrFirstFailed'
        # JS Promise.all semantics — short-circuit on first terminal failure;
        # otherwise return all values joined with '|'.
        entries = cmd['commands'].map { |c| create_future_for_command(c) }
        futures = entries.map(&:last)
        Restate.all(*futures) # raises on first failure
        result = entries.map { |type, future| await_future_result(type, future).to_s }.join('|')
      end

      last_results = Restate.get('results') || []
      last_results << result
      Restate.set('results', last_results)
    end

    result
  end
end
