# frozen_string_literal: true

require 'json'
require 'restate'

# Command kind constants
SET_STATE = 1
GET_STATE = 2
CLEAR_STATE = 3
INCREMENT_STATE_COUNTER = 4
INCREMENT_STATE_COUNTER_INDIRECTLY = 5
SLEEP = 6
CALL_SERVICE = 7
CALL_SLOW_SERVICE = 8
INCREMENT_VIA_DELAYED_CALL = 9
SIDE_EFFECT = 10
THROWING_SIDE_EFFECT = 11
SLOW_SIDE_EFFECT = 12
RECOVER_TERMINAL_CALL = 13
RECOVER_TERMINAL_MAYBE_UN_AWAITED = 14
AWAIT_PROMISE = 15
RESOLVE_AWAKEABLE = 16
REJECT_AWAKEABLE = 17
INCREMENT_STATE_COUNTER_VIA_AWAKEABLE = 18
CALL_NEXT_LAYER_OBJECT = 19

class ServiceInterpreterHelper < Restate::Service
  handler def ping
    nil
  end

  handler :echo, input: String, output: String
  def echo(param)
    param
  end

  handler def echoLater(req) # rubocop:disable Naming/MethodName
    Restate.sleep(req['sleep'] / 1000.0).await
    req['parameter']
  end

  handler def terminalFailure # rubocop:disable Naming/MethodName
    raise Restate::TerminalError, 'bye'
  end

  handler def incrementIndirectly(param) # rubocop:disable Naming/MethodName
    layer = param['layer']
    key = param['key']
    program = { 'commands' => [{ 'kind' => INCREMENT_STATE_COUNTER }] }
    raw = JSON.generate(program).b
    Restate.generic_send("ObjectInterpreterL#{layer}", 'interpret', raw, key: key)
    nil
  end

  handler def resolveAwakeable(aid) # rubocop:disable Naming/MethodName
    Restate.resolve_awakeable(aid, 'ok')
    nil
  end

  handler def rejectAwakeable(aid) # rubocop:disable Naming/MethodName
    Restate.reject_awakeable(aid, 'error')
    nil
  end

  handler def incrementViaAwakeableDance(input) # rubocop:disable Naming/MethodName
    tx_promise_id = input['txPromiseId']
    layer = input['interpreter']['layer']
    key = input['interpreter']['key']

    aid, promise = Restate.awakeable
    Restate.resolve_awakeable(tx_promise_id, aid)
    promise.await

    program = { 'commands' => [{ 'kind' => INCREMENT_STATE_COUNTER }] }
    raw = JSON.generate(program).b
    Restate.generic_send("ObjectInterpreterL#{layer}", 'interpret', raw, key: key)
    nil
  end
end

# Interprets a program of commands against the VM.
# rubocop:disable Metrics
def interpret_program(layer, program)
  coros = {} # index => [expected, future]

  await_promise = lambda do |index|
    return unless coros.key?(index)

    expected, future, deserialize = coros.delete(index)
    begin
      raw = future.await
      result = if deserialize && raw && !raw.empty?
                 Restate::JsonSerde.deserialize(raw)
               else
                 raw
               end
    rescue Restate::TerminalError
      result = 'rejected'
    end

    raise Restate::TerminalError, "Expected #{expected} but got #{result}" if result != expected
  end

  program['commands'].each_with_index do |cmd, i|
    if cmd['kind'] == AWAIT_PROMISE
      await_promise.call(cmd['index'])
    else
      interpret_one(layer, cmd, i, coros)
    end
    await_promise.call(i)
  end
end

def interpret_one(layer, cmd, i, coros) # rubocop:disable Naming/MethodParameterName
  case cmd['kind']
  when SET_STATE then Restate.set("key-#{cmd['key']}", "value-#{cmd['key']}")
  when GET_STATE then Restate.get("key-#{cmd['key']}")
  when CLEAR_STATE then Restate.clear("key-#{cmd['key']}")
  when INCREMENT_STATE_COUNTER
    c = Restate.get('counter') || 0
    Restate.set('counter', c + 1)
  when SLEEP then Restate.sleep(cmd['duration'] / 1000.0).await
  when CALL_SERVICE
    expected = "hello-#{i}"
    coros[i] = [expected, Restate.generic_call('ServiceInterpreterHelper', 'echo',
                                               Restate::JsonSerde.serialize(expected)), true]
  when CALL_SLOW_SERVICE
    expected = "hello-#{i}"
    arg = { 'parameter' => expected, 'sleep' => cmd['sleep'] }
    coros[i] = [expected, Restate.generic_call('ServiceInterpreterHelper', 'echoLater',
                                               Restate::JsonSerde.serialize(arg)), true]
  when INCREMENT_VIA_DELAYED_CALL
    delay = cmd['duration'] / 1000.0
    arg = { 'layer' => layer, 'key' => Restate.key }
    Restate.generic_send('ServiceInterpreterHelper', 'incrementIndirectly',
                         Restate::JsonSerde.serialize(arg), delay: delay)
  when SIDE_EFFECT
    expected = "hello-#{i}"
    result = Restate.run_sync('sideEffect') { expected }
    raise Restate::TerminalError, "Expected #{expected} but got #{result}" if result != expected
  when SLOW_SIDE_EFFECT then :noop
  when RECOVER_TERMINAL_CALL then recover_terminal_call
  when RECOVER_TERMINAL_MAYBE_UN_AWAITED then :noop # rubocop:disable Lint/DuplicateBranch
  when THROWING_SIDE_EFFECT
    Restate.run_sync('throwingSideEffect') { raise StandardError, 'Random error' if rand(2) == 1 }
  when INCREMENT_STATE_COUNTER_INDIRECTLY
    arg = { 'layer' => layer, 'key' => Restate.key }
    Restate.generic_send('ServiceInterpreterHelper', 'incrementIndirectly',
                         Restate::JsonSerde.serialize(arg))
  # AWAIT_PROMISE is handled in the caller (interpret_program)
  when RESOLVE_AWAKEABLE then handle_resolve_awakeable(i, coros)
  when REJECT_AWAKEABLE then handle_reject_awakeable(i, coros)
  when INCREMENT_STATE_COUNTER_VIA_AWAKEABLE
    handle_increment_via_awakeable(layer, coros)
  when CALL_NEXT_LAYER_OBJECT
    handle_call_next_layer(layer, cmd, i, coros)
  else
    raise Restate::TerminalError, "Unknown command type: #{cmd['kind']}"
  end
end

def recover_terminal_call
  Restate.generic_call('ServiceInterpreterHelper', 'terminalFailure',
                       Restate::JsonSerde.serialize(nil)).await
  raise Restate::TerminalError, 'Expected terminal error'
rescue Restate::TerminalError
  nil # expected
end

def handle_resolve_awakeable(idx, coros)
  aid, promise = Restate.awakeable
  coros[idx] = ['ok', promise, false]
  Restate.generic_send('ServiceInterpreterHelper', 'resolveAwakeable',
                       Restate::JsonSerde.serialize(aid))
end

def handle_reject_awakeable(idx, coros)
  aid, promise = Restate.awakeable
  coros[idx] = ['rejected', promise, false]
  Restate.generic_send('ServiceInterpreterHelper', 'rejectAwakeable',
                       Restate::JsonSerde.serialize(aid))
end

def handle_increment_via_awakeable(layer, _coros)
  tx_aid, tx_promise = Restate.awakeable
  arg = { 'interpreter' => { 'layer' => layer, 'key' => Restate.key }, 'txPromiseId' => tx_aid }
  Restate.generic_send('ServiceInterpreterHelper', 'incrementViaAwakeableDance',
                       Restate::JsonSerde.serialize(arg))
  their_aid = tx_promise.await
  Restate.resolve_awakeable(their_aid, 'ok')
end

def handle_call_next_layer(layer, cmd, idx, coros)
  next_layer = "ObjectInterpreterL#{layer + 1}"
  key = cmd['key'].to_s
  raw = JSON.generate(cmd['program']).b
  coros[idx] = [''.b, Restate.generic_call(next_layer, 'interpret', raw, key: key), false]
end
# rubocop:enable Metrics

# Base module for interpreter layer VirtualObjects.
module InterpreterLayer # rubocop:disable Style/OneClassPerFile
  def self.included(base)
    base.extend(ClassMethods)
  end

  module ClassMethods
    def interpreter_layer(num)
      @_layer = num
      service_name "ObjectInterpreterL#{num}"
    end

    attr_reader :_layer
  end
end

class ObjectInterpreterL0 < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  include InterpreterLayer

  interpreter_layer 0

  handler def interpret(program)
    interpret_program(self.class._layer, program)
    nil
  end

  shared def counter
    Restate.get('counter') || 0
  end
end

class ObjectInterpreterL1 < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  include InterpreterLayer

  interpreter_layer 1

  handler def interpret(program)
    interpret_program(self.class._layer, program)
    nil
  end

  shared def counter
    Restate.get('counter') || 0
  end
end

class ObjectInterpreterL2 < Restate::VirtualObject # rubocop:disable Style/OneClassPerFile
  include InterpreterLayer

  interpreter_layer 2

  handler def interpret(program)
    interpret_program(self.class._layer, program)
    nil
  end

  shared def counter
    Restate.get('counter') || 0
  end
end
