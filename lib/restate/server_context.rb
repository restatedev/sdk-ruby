# frozen_string_literal: true

require "async"
require "async/queue"
require "logger"

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
    LOGGER = Logger.new($stdout, progname: "Restate::ServerContext")

    attr_reader :vm, :invocation

    def initialize(vm:, handler:, invocation:, send_output:, input_queue:)
      @vm = vm
      @handler = handler
      @invocation = invocation
      @send_output = send_output
      @input_queue = input_queue
      @run_coros_to_execute = {}
    end

    # ── Main entry point ──

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
    rescue => e
      # Walk the cause chain for TerminalError or internal exceptions
      cause = e
      handled = false
      while cause
        if cause.is_a?(TerminalError)
          failure = Failure.new(code: cause.status_code, message: cause.message)
          @vm.sys_write_output_failure(failure)
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

    def get(name)
      handle = @vm.sys_get_state(name)
      poll_and_take(handle) do |raw|
        raw.nil? ? nil : JsonSerde.deserialize(raw)
      end
    end

    def set(name, value)
      @vm.sys_set_state(name, JsonSerde.serialize(value).b)
    end

    def clear(name)
      @vm.sys_clear_state(name)
    end

    def clear_all
      @vm.sys_clear_all_state
    end

    def state_keys
      handle = @vm.sys_get_state_keys
      poll_and_take(handle)
    end

    # ── Sleep ──

    def sleep(seconds)
      millis = (seconds * 1000).to_i
      handle = @vm.sys_sleep(millis)
      poll_and_take(handle)
      nil
    end

    # ── Durable run (side effect) ──

    def run(name, &action)
      raise ArgumentError, "Block required for run" unless block_given?

      handle = @vm.sys_run(name)

      @run_coros_to_execute[handle] = -> { execute_run(handle, action) }

      poll_and_take(handle) do |raw|
        raw.nil? ? nil : JsonSerde.deserialize(raw)
      end
    end

    # ── Service calls ──

    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil)
      parameter = JsonSerde.serialize(arg)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(call_handle.result_handle) do |raw|
        raw.nil? ? nil : JsonSerde.deserialize(raw)
      end
    end

    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil)
      parameter = JsonSerde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      @vm.sys_send(
        service: service, handler: handler, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
    end

    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil)
      parameter = JsonSerde.serialize(arg)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      poll_and_take(call_handle.result_handle) do |raw|
        raw.nil? ? nil : JsonSerde.deserialize(raw)
      end
    end

    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil)
      parameter = JsonSerde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      @vm.sys_send(
        service: service, handler: handler, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
    end

    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil)
      object_call(service, handler, key, arg, idempotency_key: idempotency_key, headers: headers)
    end

    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil)
      object_send(service, handler, key, arg, delay: delay, idempotency_key: idempotency_key, headers: headers)
    end

    # ── Request metadata ──

    def request
      Request.new(
        id: @invocation.invocation_id,
        headers: @invocation.headers.to_h,
        body: @invocation.input_buffer
      )
    end

    def key
      @invocation.key
    end

    private

    # ── Progress loop ──

    # Polls until the given handle(s) complete, then takes the notification.
    def poll_and_take(handle, &transform)
      poll_or_cancel([handle]) unless @vm.is_completed(handle)
      must_take_notification(handle, &transform)
    end

    def poll_or_cancel(handles)
      loop do
        flush_output
        response = @vm.do_progress(handles)

        if response.is_a?(Exception)
          LOGGER.error("Exception in do_progress: #{response}")
          flush_output
          raise InternalError.new
        end

        case response
        when Suspended
          flush_output
          raise SuspendedError.new
        when DoProgressAnyCompleted
          return
        when DoProgressCancelSignalReceived
          raise TerminalError.new("cancelled", status_code: 409)
        when DoProgressExecuteRun
          fn = @run_coros_to_execute.delete(response.handle)
          raise "Missing run coroutine for handle #{response.handle}" unless fn

          # Spawn child task for the run action
          Async do
            begin
              fn.call
            ensure
              @input_queue.enqueue(:run_completed)
            end
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
            raise DisconnectedError.new
          when String
            @vm.notify_input(event)
          end
        end
      end
    end

    def must_take_notification(handle)
      result = @vm.take_notification(handle)

      if result.is_a?(Exception)
        flush_output
        LOGGER.error("Exception in take_notification: #{result}")
        raise InternalError.new
      end

      case result
      when Suspended
        flush_output
        raise SuspendedError.new
      when NotReady
        raise "Unexpected NotReady for handle #{handle}"
      when Failure
        raise TerminalError.new(result.message, status_code: result.code)
      else
        block_given? ? yield(result) : result
      end
    end

    def flush_output
      output = @vm.take_output
      @send_output.call(output) if output
    end

    # ── Run execution ──

    def execute_run(handle, action)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = action.call
        buffer = JsonSerde.serialize(result)
        @vm.propose_run_completion_success(handle, buffer.b)
      rescue TerminalError => e
        failure = Failure.new(code: e.status_code, message: e.message)
        @vm.propose_run_completion_failure(handle, failure)
      rescue SuspendedError, InternalError
        raise
      rescue => e
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        attempt_duration_ms = (elapsed * 1000).to_i
        failure = Failure.new(
          code: 500,
          message: e.inspect,
          stacktrace: e.backtrace&.join("\n")
        )
        config = RunRetryConfig.new
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
