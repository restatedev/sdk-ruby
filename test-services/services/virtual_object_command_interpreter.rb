# typed: false
# frozen_string_literal: true

require 'json'
require 'restate'

VIRTUAL_OBJECT_COMMAND_INTERPRETER = Restate.virtual_object('VirtualObjectCommandInterpreter')

VIRTUAL_OBJECT_COMMAND_INTERPRETER.handler('getResults', kind: :shared) do |ctx|
  ctx.get('results') || []
end

VIRTUAL_OBJECT_COMMAND_INTERPRETER.handler('hasAwakeable', kind: :shared) do |ctx, awk_key|
  awk_id = ctx.get("awk-#{awk_key}")
  !awk_id.nil?
end

VIRTUAL_OBJECT_COMMAND_INTERPRETER.handler('resolveAwakeable', kind: :shared) do |ctx, req|
  awk_id = ctx.get("awk-#{req['awakeableKey']}")
  raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

  ctx.resolve_awakeable(awk_id, req['value'])
  nil
end

VIRTUAL_OBJECT_COMMAND_INTERPRETER.handler('rejectAwakeable', kind: :shared) do |ctx, req|
  awk_id = ctx.get("awk-#{req['awakeableKey']}")
  raise Restate::TerminalError, 'No awakeable is registered' unless awk_id

  ctx.reject_awakeable(awk_id, req['reason'])
  nil
end

def decode_handle_result(type, raw)
  return 'sleep' if type == :sleep

  JSON.parse(raw)
end

def create_handle_for_command(ctx, cmd) # rubocop:disable Metrics/MethodLength,Metrics/AbcSize
  case cmd['type']
  when 'createAwakeable'
    awk_id, handle = ctx.create_awakeable
    ctx.set("awk-#{cmd['awakeableKey']}", awk_id)
    [:awakeable, handle]
  when 'sleep'
    handle = ctx.create_sleep(cmd['timeoutMillis'] / 1000.0)
    [:sleep, handle]
  when 'runThrowTerminalException'
    # We can't create a run handle without blocking in the same way.
    # Execute it as a run that throws, and let it be caught.
    reason = cmd['reason']
    handle = ctx.vm.sys_run('run should fail command')
    ctx.instance_variable_get(:@run_coros_to_execute)[handle] = lambda {
      failure = Restate::Failure.new(code: 500, message: reason)
      ctx.vm.propose_run_completion_failure(handle, failure)
    }
    [:run, handle]
  end
end

VIRTUAL_OBJECT_COMMAND_INTERPRETER.handler('interpretCommands') do |ctx, req| # rubocop:disable Metrics/BlockLength
  result = ''

  req['commands'].each do |cmd| # rubocop:disable Metrics/BlockLength
    case cmd['type']
    when 'awaitAwakeableOrTimeout'
      awk_id, awk_handle = ctx.create_awakeable
      ctx.set("awk-#{cmd['awakeableKey']}", awk_id)
      sleep_handle = ctx.create_sleep(cmd['timeoutMillis'] / 1000.0)

      ctx.wait_any_handle([awk_handle, sleep_handle])

      if ctx.completed?(awk_handle)
        result = JSON.parse(ctx.take_completed(awk_handle))
      else
        ctx.take_completed(sleep_handle)
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
      result = ctx.run('get_env') { ENV.fetch(env_name, '') }

    when 'awaitOne'
      type, handle = create_handle_for_command(ctx, cmd['command'])
      raw = ctx.resolve_handle(handle)
      result = decode_handle_result(type, raw)

    when 'awaitAny'
      entries = cmd['commands'].map { |c| create_handle_for_command(ctx, c) }
      handles = entries.map(&:last)
      ctx.wait_any_handle(handles)
      idx = entries.index { |_, h| ctx.completed?(h) }
      type, handle = entries[idx]
      raw = ctx.take_completed(handle)
      result = decode_handle_result(type, raw)

    when 'awaitAnySuccessful'
      entries = cmd['commands'].map { |c| create_handle_for_command(ctx, c) }
      remaining = entries.dup
      found = false
      until remaining.empty?
        handles = remaining.map(&:last)
        ctx.wait_any_handle(handles)
        idx = remaining.index { |_, h| ctx.completed?(h) }
        type, handle = remaining[idx]
        begin
          raw = ctx.take_completed(handle)
          result = decode_handle_result(type, raw)
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
