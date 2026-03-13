# typed: true
# frozen_string_literal: true

require 'async'
require 'async/queue'
require 'logger'

module Restate
  # The core execution context for a Restate handler invocation.
  # Implements the progress loop and all context API methods (state, run, sleep, call, send).
  #
  # Concurrency model:
  #   - The handler runs inside a Fiber managed by Falcon/Async.
  #   - `run` blocks spawn child Async tasks.
  #   - When the progress loop needs input, it dequeues from @input_queue, yielding the Fiber.
  #   - The HTTP input reader (a separate Async task) feeds chunks into @input_queue.
  #   - Output chunks are written directly to the streaming response body.
  class ServerContext
    extend T::Sig

    LOGGER = T.let(Logger.new($stdout, progname: 'Restate::ServerContext'), Logger)

    sig { returns(VMWrapper) }
    attr_reader :vm

    sig { returns(T.untyped) }
    attr_reader :invocation

    sig { params(vm: VMWrapper, handler: T.untyped, invocation: T.untyped, send_output: T.untyped, input_queue: Async::Queue).void }
    def initialize(vm:, handler:, invocation:, send_output:, input_queue:)
      @vm = T.let(vm, VMWrapper)
      @handler = T.let(handler, T.untyped)
      @invocation = T.let(invocation, T.untyped)
      @send_output = T.let(send_output, T.untyped)
      @input_queue = T.let(input_queue, Async::Queue)
      @run_coros_to_execute = T.let({}, T::Hash[Integer, T.untyped])
    end

    # ── Main entry point ──

    sig { void }
    def enter
      in_buffer = @invocation.input_buffer
      out_buffer = Restate.invoke_handler(handler: @handler, ctx: self, in_buffer: in_buffer)
      @vm.sys_write_output_success(out_buffer.b)
      @vm.sys_end
    rescue TerminalError => e
      failure = Failure.new(code: e.status_code, message: e.message)
      @vm.sys_write_output_failure(failure)
      @vm.sys_end
    rescue SuspendedError, InternalError
      # These are expected internal control flow exceptions; do nothing.
    rescue DisconnectedError
      raise
    rescue StandardError => e
      # Walk the cause chain for TerminalError or internal exceptions
      cause = T.let(e, T.nilable(Exception))
      handled = T.let(false, T::Boolean)
      while cause
        if cause.is_a?(TerminalError)
          f = Failure.new(code: cause.status_code, message: cause.message)
          @vm.sys_write_output_failure(f)
          @vm.sys_end
          handled = true
          break
        elsif cause.is_a?(SuspendedError) || cause.is_a?(InternalError)
          handled = true
          break
        end
        cause = cause.cause
      end
      unless handled
        @vm.notify_error(e.inspect, e.backtrace&.join("\n"))
        raise
      end
    end

    # ── State operations ──

    sig { params(name: String, serde: T.untyped).returns(T.untyped) }
    def get(name, serde: JsonSerde)
      handle = @vm.sys_get_state(name)
      poll_and_take(handle) do |raw|
        raw.nil? ? nil : serde.deserialize(raw)
      end
    end

    sig { params(name: String, value: T.untyped, serde: T.untyped).void }
    def set(name, value, serde: JsonSerde)
      @vm.sys_set_state(name, serde.serialize(value).b)
    end

    sig { params(name: String).void }
    def clear(name)
      @vm.sys_clear_state(name)
    end

    sig { void }
    def clear_all
      @vm.sys_clear_all_state
    end

    sig { returns(T.untyped) }
    def state_keys
      handle = @vm.sys_get_state_keys
      poll_and_take(handle)
    end

    # ── Sleep ──

    sig { params(seconds: Numeric).returns(NilClass) }
    def sleep(seconds)
      millis = (seconds * 1000).to_i
      handle = @vm.sys_sleep(millis)
      poll_and_take(handle)
      nil
    end

    # Create a sleep timer without blocking. Returns a handle (Integer).
    sig { params(seconds: Numeric).returns(Integer) }
    def create_sleep(seconds)
      millis = (seconds * 1000).to_i
      @vm.sys_sleep(millis)
    end

    # Block until a previously created handle completes.
    sig { params(handle: Integer).returns(NilClass) }
    def resolve_handle(handle)
      poll_and_take(handle)
      nil
    end

    # ── Durable run (side effect) ──

    sig do
      params(
        name: String,
        serde: T.untyped,
        retry_policy: T.nilable(RunRetryPolicy),
        action: T.proc.returns(T.untyped)
      ).returns(T.untyped)
    end
    def run(name, serde: JsonSerde, retry_policy: nil, &action)
      handle = @vm.sys_run(name)

      @run_coros_to_execute[handle] = -> { execute_run(handle, action, serde, retry_policy) }

      poll_and_take(handle) do |raw|
        raw.nil? ? nil : serde.deserialize(raw)
      end
    end

    # ── Service calls ──

    sig do
      params(
        service: String,
        handler: String,
        arg: T.untyped,
        key: T.nilable(String),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped,
        output_serde: T.untyped
      ).returns(T.untyped)
    end
    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     input_serde: JsonSerde, output_serde: JsonSerde)
      parameter = input_serde.serialize(arg)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(call_handle.result_handle) do |raw|
        raw.nil? ? nil : output_serde.deserialize(raw)
      end
    end

    sig do
      params(
        service: String,
        handler: String,
        arg: T.untyped,
        key: T.nilable(String),
        delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).void
    end
    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil,
                     input_serde: JsonSerde)
      parameter = input_serde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      @vm.sys_send(
        service: service, handler: handler, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
    end

    sig do
      params(
        service: String,
        handler: String,
        key: String,
        arg: T.untyped,
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped,
        output_serde: T.untyped
      ).returns(T.untyped)
    end
    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: JsonSerde, output_serde: JsonSerde)
      parameter = input_serde.serialize(arg)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(call_handle.result_handle) do |raw|
        raw.nil? ? nil : output_serde.deserialize(raw)
      end
    end

    sig do
      params(
        service: String,
        handler: String,
        key: String,
        arg: T.untyped,
        delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).void
    end
    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil,
                    input_serde: JsonSerde)
      parameter = input_serde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      @vm.sys_send(
        service: service, handler: handler, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
    end

    sig do
      params(
        service: String,
        handler: String,
        key: String,
        arg: T.untyped,
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped,
        output_serde: T.untyped
      ).returns(T.untyped)
    end
    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                      input_serde: JsonSerde, output_serde: JsonSerde)
      object_call(service, handler, key, arg, idempotency_key: idempotency_key, headers: headers,
                  input_serde: input_serde, output_serde: output_serde) # rubocop:disable Layout/HashAlignment
    end

    sig do
      params(
        service: String,
        handler: String,
        key: String,
        arg: T.untyped,
        delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String]),
        input_serde: T.untyped
      ).void
    end
    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil,
                      input_serde: JsonSerde)
      object_send(service, handler, key, arg, delay: delay, idempotency_key: idempotency_key, headers: headers,
                  input_serde: input_serde) # rubocop:disable Layout/HashAlignment
    end

    # ── Generic calls (raw bytes, no serde) ──

    sig do
      params(
        service: String,
        handler: String,
        arg: String,
        key: T.nilable(String),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(T.untyped)
    end
    def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: arg.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(call_handle.result_handle)
    end

    sig do
      params(
        service: String,
        handler: String,
        arg: String,
        key: T.nilable(String),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(Integer)
    end
    def generic_call_handle(service, handler, arg, key: nil, idempotency_key: nil, headers: nil)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: arg.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      call_handle.result_handle
    end

    sig do
      params(
        service: String,
        handler: String,
        arg: String,
        key: T.nilable(String),
        delay: T.nilable(Numeric),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(T.untyped)
    end
    def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil)
      delay_ms = delay ? (delay * 1000).to_i : nil
      invocation_id_handle = @vm.sys_send(
        service: service, handler: handler, parameter: arg.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(invocation_id_handle)
    end

    # ── Request metadata ──

    sig { returns(T.untyped) }
    def request
      Request.new(
        id: @invocation.invocation_id,
        headers: @invocation.headers.to_h,
        body: @invocation.input_buffer
      )
    end

    sig { returns(String) }
    def key
      @invocation.key
    end

    private

    # ── Progress loop ──

    # Polls until the given handle(s) complete, then takes the notification.
    sig do
      params(
        handle: Integer,
        block: T.nilable(T.proc.params(arg0: T.untyped).returns(T.untyped))
      ).returns(T.untyped)
    end
    def poll_and_take(handle, &block)
      poll_or_cancel([handle]) unless @vm.is_completed(handle)
      must_take_notification(handle, &block)
    end

    sig { params(handles: T::Array[Integer]).void }
    def poll_or_cancel(handles)
      loop do
        flush_output
        response = @vm.do_progress(handles)

        if response.is_a?(Exception)
          LOGGER.error("Exception in do_progress: #{response}")
          flush_output
          raise InternalError
        end

        case response
        when Suspended
          flush_output
          raise SuspendedError
        when DoProgressAnyCompleted
          return
        when DoProgressCancelSignalReceived
          raise TerminalError.new('cancelled', status_code: 409)
        when DoProgressExecuteRun
          fn = @run_coros_to_execute.delete(response.handle)
          raise "Missing run coroutine for handle #{response.handle}" unless fn

          # Spawn child task for the run action
          Async do
            fn.call
          ensure
            @input_queue.enqueue(:run_completed)
          end
        when DoWaitPendingRun, DoProgressReadFromInput
          # Wait for input from the HTTP body reader or a run completion signal
          event = @input_queue.dequeue

          case event
          when :run_completed
            next
          when :eof
            @vm.notify_input_closed
          when :disconnected
            raise DisconnectedError
          when String
            @vm.notify_input(event)
          end
        end
      end
    end

    sig do
      params(
        handle: Integer,
        block: T.nilable(T.proc.params(arg0: T.untyped).returns(T.untyped))
      ).returns(T.untyped)
    end
    def must_take_notification(handle, &block)
      result = @vm.take_notification(handle)

      if result.is_a?(Exception)
        flush_output
        LOGGER.error("Exception in take_notification: #{result}")
        raise InternalError
      end

      case result
      when Suspended
        flush_output
        raise SuspendedError
      when NotReady
        raise "Unexpected NotReady for handle #{handle}"
      when Failure
        raise TerminalError.new(result.message, status_code: result.code)
      else
        block ? yield(result) : result
      end
    end

    sig { void }
    def flush_output
      loop do
        output = @vm.take_output
        break if output.nil? || output.empty?

        @send_output.call(output)
      end
    end

    # ── Run execution ──

    sig do
      params(
        handle: Integer,
        action: T.proc.returns(T.untyped),
        serde: T.untyped,
        retry_policy: T.nilable(RunRetryPolicy)
      ).void
    end
    def execute_run(handle, action, serde, retry_policy)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = action.call
        buffer = serde.serialize(result)
        @vm.propose_run_completion_success(handle, buffer.b)
      rescue TerminalError => e
        failure = Failure.new(code: e.status_code, message: e.message)
        @vm.propose_run_completion_failure(handle, failure)
      rescue SuspendedError, InternalError
        raise
      rescue StandardError => e
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        attempt_duration_ms = (elapsed * 1000).to_i
        failure = Failure.new(
          code: 500,
          message: e.inspect,
          stacktrace: e.backtrace&.join("\n")
        )
        config = RunRetryConfig.new(
          initial_interval: retry_policy&.initial_interval,
          max_attempts: retry_policy&.max_attempts,
          max_duration: retry_policy&.max_duration,
          max_interval: retry_policy&.max_interval,
          interval_factor: retry_policy&.interval_factor
        )
        @vm.propose_run_completion_transient(
          handle,
          failure: failure,
          attempt_duration_ms: attempt_duration_ms,
          config: config
        )
      end
    end
  end
end
