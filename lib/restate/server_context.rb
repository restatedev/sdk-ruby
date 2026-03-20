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
    include WorkflowContext
    include WorkflowSharedContext

    LOGGER = Logger.new($stdout, progname: 'Restate::ServerContext')

    attr_reader :vm, :invocation

    def initialize(vm:, handler:, invocation:, send_output:, input_queue:, middleware: [])
      @vm = vm
      @handler = handler
      @invocation = invocation
      @send_output = send_output
      @input_queue = input_queue
      @run_coros_to_execute = {}
      @attempt_finished_event = AttemptFinishedEvent.new
      @middleware = middleware
    end

    # ── Main entry point ──

    # Runs the handler to completion, writing the output (or failure) to the journal.
    def enter
      Thread.current[:restate_context] = self
      Thread.current[:restate_service_kind] = @handler.service_tag.kind
      Thread.current[:restate_handler_kind] = @handler.kind
      in_buffer = @invocation.input_buffer
      out_buffer = Restate.invoke_handler(handler: @handler, ctx: self, in_buffer: in_buffer,
                                          middleware: @middleware)
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
      cause = e
      handled = false
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
    ensure
      @run_coros_to_execute.clear
      Thread.current[:restate_context] = nil
      Thread.current[:restate_service_kind] = nil
      Thread.current[:restate_handler_kind] = nil
    end

    # Called by the server when the attempt ends (handler completed, disconnected,
    # or transient error). Signals the attempt_finished_event so that user code
    # and background pool jobs can clean up.
    def on_attempt_finished
      @attempt_finished_event.set!
    end

    # ── State operations ──

    # Durably retrieves a state entry by name. Returns nil if unset.
    def get(name, serde: JsonSerde)
      get_async(name, serde: serde).await
    end

    # Returns a DurableFuture for a state entry. Resolves to nil if unset.
    def get_async(name, serde: JsonSerde)
      handle = @vm.sys_get_state(name)
      DurableFuture.new(self, handle, serde: serde)
    end

    # Durably sets a state entry. The value is serialized via +serde+.
    def set(name, value, serde: JsonSerde)
      @vm.sys_set_state(name, serde.serialize(value).b)
    end

    # Durably removes a single state entry by name.
    def clear(name)
      @vm.sys_clear_state(name)
    end

    # Durably removes all state entries for this virtual object or workflow.
    def clear_all
      @vm.sys_clear_all_state
    end

    # Returns the list of all state entry names for this virtual object or workflow.
    def state_keys
      state_keys_async.await
    end

    # Returns a DurableFuture for the list of all state entry names.
    def state_keys_async
      handle = @vm.sys_get_state_keys
      DurableFuture.new(self, handle)
    end

    # ── Sleep ──

    # Returns a durable future that completes after the given duration.
    # The timer survives handler restarts.
    def sleep(seconds)
      millis = (seconds * 1000).to_i
      handle = @vm.sys_sleep(millis)
      DurableFuture.new(self, handle)
    end

    # Block until a previously created handle completes. Returns the value.
    def resolve_handle(handle)
      poll_and_take(handle)
    end

    # Wait until any of the given handles completes. Does not take notifications.
    def wait_any_handle(handles)
      poll_or_cancel(handles) unless handles.any? { |h| @vm.is_completed(h) }
    end

    # Check if a handle is completed (non-blocking).
    def completed?(handle)
      @vm.is_completed(handle)
    end

    # Take a completed handle's notification, returning the value.
    # Raises TerminalError if the handle resolved to a failure.
    def take_completed(handle)
      must_take_notification(handle)
    end

    # Wait until any of the given futures completes. Returns [completed, remaining].
    def wait_any(*futures)
      handles = futures.map(&:handle)
      wait_any_handle(handles)
      completed = []
      remaining = []
      futures.each do |f|
        if f.completed?
          completed << f
        else
          remaining << f
        end
      end
      [completed, remaining]
    end

    # ── Durable run (side effect) ──

    # Executes a durable side effect. The block runs at most once; its result is
    # journaled and replayed on retries. Returns a DurableFuture for the result.
    #
    # Pass +background: true+ to run the block in a real OS Thread, keeping the
    # fiber event loop responsive for other concurrent handlers. Use this for
    # CPU-intensive work.
    def run(name, serde: JsonSerde, retry_policy: nil, background: false, &action)
      handle = @vm.sys_run(name)

      executor = background ? :execute_run_threaded : :execute_run
      @run_coros_to_execute[handle] = -> { send(executor, handle, action, serde, retry_policy) }

      DurableFuture.new(self, handle, serde: serde)
    end

    # Convenience shortcut for +run(...).await+ — executes the durable side effect
    # and returns the result directly.
    #
    # Accepts all the same options as +run+, including +background: true+.
    def run_sync(name, serde: JsonSerde, retry_policy: nil, background: false, &action)
      run(name, serde: serde, retry_policy: retry_policy, background: background, &action).await
    end

    # ── Service calls ──

    # Durably calls a handler on a Restate service and returns a future for its result.
    def service_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil,
                     input_serde: NOT_SET, output_serde: NOT_SET)
      svc_name, handler_name, handler_meta = resolve_call_target(service, handler)
      in_serde = resolve_serde(input_serde, handler_meta, :input_serde)
      out_serde = resolve_serde(output_serde, handler_meta, :output_serde)
      parameter = in_serde.serialize(arg)
      call_handle = @vm.sys_call(
        service: svc_name, handler: handler_name, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      DurableCallFuture.new(self, call_handle.result_handle, call_handle.invocation_id_handle,
                            output_serde: out_serde)
    end

    # Sends a one-way invocation to a Restate service handler (fire-and-forget).
    def service_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil,
                     input_serde: NOT_SET)
      svc_name, handler_name, handler_meta = resolve_call_target(service, handler)
      in_serde = resolve_serde(input_serde, handler_meta, :input_serde)
      parameter = in_serde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      invocation_id_handle = @vm.sys_send(
        service: svc_name, handler: handler_name, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
      SendHandle.new(self, invocation_id_handle)
    end

    # Durably calls a handler on a Restate virtual object, keyed by +key+.
    def object_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                    input_serde: NOT_SET, output_serde: NOT_SET)
      svc_name, handler_name, handler_meta = resolve_call_target(service, handler)
      in_serde = resolve_serde(input_serde, handler_meta, :input_serde)
      out_serde = resolve_serde(output_serde, handler_meta, :output_serde)
      parameter = in_serde.serialize(arg)
      call_handle = @vm.sys_call(
        service: svc_name, handler: handler_name, parameter: parameter.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      DurableCallFuture.new(self, call_handle.result_handle, call_handle.invocation_id_handle,
                            output_serde: out_serde)
    end

    # Sends a one-way invocation to a Restate virtual object handler (fire-and-forget).
    def object_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil,
                    input_serde: NOT_SET)
      svc_name, handler_name, handler_meta = resolve_call_target(service, handler)
      in_serde = resolve_serde(input_serde, handler_meta, :input_serde)
      parameter = in_serde.serialize(arg)
      delay_ms = delay ? (delay * 1000).to_i : nil
      invocation_id_handle = @vm.sys_send(
        service: svc_name, handler: handler_name, parameter: parameter.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
      SendHandle.new(self, invocation_id_handle)
    end

    # Durably calls a handler on a Restate workflow, keyed by +key+.
    def workflow_call(service, handler, key, arg, idempotency_key: nil, headers: nil,
                      input_serde: NOT_SET, output_serde: NOT_SET)
      object_call(service, handler, key, arg, idempotency_key: idempotency_key, headers: headers,
                  input_serde: input_serde, output_serde: output_serde) # rubocop:disable Layout/HashAlignment
    end

    # Sends a one-way invocation to a Restate workflow handler (fire-and-forget).
    def workflow_send(service, handler, key, arg, delay: nil, idempotency_key: nil, headers: nil,
                      input_serde: NOT_SET)
      object_send(service, handler, key, arg, delay: delay, idempotency_key: idempotency_key, headers: headers,
                  input_serde: input_serde) # rubocop:disable Layout/HashAlignment
    end

    # ── Awakeables ──

    # Creates an awakeable and returns [awakeable_id, DurableFuture].
    def awakeable(serde: JsonSerde)
      id, handle = @vm.sys_awakeable
      [id, DurableFuture.new(self, handle, serde: serde)]
    end

    # Resolves an awakeable with a success value.
    def resolve_awakeable(awakeable_id, payload, serde: JsonSerde)
      @vm.sys_complete_awakeable_success(awakeable_id, serde.serialize(payload).b)
    end

    # Rejects an awakeable with a terminal failure.
    def reject_awakeable(awakeable_id, message, code: 500)
      failure = Failure.new(code: code, message: message)
      @vm.sys_complete_awakeable_failure(awakeable_id, failure)
    end

    # ── Promises (Workflow API) ──

    # Gets a durable promise value, blocking until resolved.
    def promise(name, serde: JsonSerde)
      handle = @vm.sys_get_promise(name)
      poll_and_take(handle) do |raw|
        raw.nil? ? nil : serde.deserialize(raw)
      end
    end

    # Peeks at a durable promise value without blocking. Returns nil if not yet resolved.
    def peek_promise(name, serde: JsonSerde)
      handle = @vm.sys_peek_promise(name)
      poll_and_take(handle) do |raw|
        raw.nil? ? nil : serde.deserialize(raw)
      end
    end

    # Resolves a durable promise with a success value.
    def resolve_promise(name, payload, serde: JsonSerde)
      handle = @vm.sys_complete_promise_success(name, serde.serialize(payload).b)
      poll_and_take(handle)
      nil
    end

    # Rejects a durable promise with a terminal failure.
    def reject_promise(name, message, code: 500)
      failure = Failure.new(code: code, message: message)
      handle = @vm.sys_complete_promise_failure(name, failure)
      poll_and_take(handle)
      nil
    end

    # ── Cancel invocation ──

    # Requests cancellation of another invocation by its id.
    def cancel_invocation(invocation_id)
      @vm.sys_cancel_invocation(invocation_id)
    end

    # ── Generic calls (raw bytes, no serde) ──

    # Durably calls a handler using raw bytes (no serialization). Useful for proxying.
    def generic_call(service, handler, arg, key: nil, idempotency_key: nil, headers: nil)
      call_handle = @vm.sys_call(
        service: service, handler: handler, parameter: arg.b,
        key: key, idempotency_key: idempotency_key, headers: headers
      )
      DurableCallFuture.new(self, call_handle.result_handle, call_handle.invocation_id_handle,
                            output_serde: nil)
    end

    # Sends a one-way invocation using raw bytes (no serialization). Useful for proxying.
    def generic_send(service, handler, arg, key: nil, delay: nil, idempotency_key: nil, headers: nil)
      delay_ms = delay ? (delay * 1000).to_i : nil
      invocation_id_handle = @vm.sys_send(
        service: service, handler: handler, parameter: arg.b,
        key: key, delay: delay_ms, idempotency_key: idempotency_key, headers: headers
      )
      SendHandle.new(self, invocation_id_handle)
    end

    # ── Request metadata ──

    # Returns metadata about the current invocation (id, headers, raw body).
    def request
      @request ||= Request.new(
        id: @invocation.invocation_id,
        headers: @invocation.headers.to_h,
        body: @invocation.input_buffer,
        attempt_finished_event: @attempt_finished_event
      )
    end

    # Returns the key for this virtual object or workflow invocation.
    def key
      @invocation.key
    end

    private

    # ── Progress loop ──

    # Polls until the given handle(s) complete, then takes the notification.
    def poll_and_take(handle, &)
      poll_or_cancel([handle]) unless @vm.is_completed(handle)
      must_take_notification(handle, &)
    end

    def poll_or_cancel(handles)
      loop do
        flush_output
        response = @vm.do_progress(handles)

        if response.is_a?(Exception)
          LOGGER.error("Exception in do_progress: #{response}")
          raise InternalError
        end

        case response
        when Suspended
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

    def flush_output
      loop do
        output = @vm.take_output
        break if output.nil? || output.empty?

        @send_output.call(output)
      end
    end

    # ── Call target resolution ──

    # Resolves a service+handler pair from class/symbol or string/string.
    # Returns [service_name, handler_name, handler_metadata_or_nil].
    def resolve_call_target(service, handler)
      if service.is_a?(Class) && service.respond_to?(:service_name)
        svc_name = service.service_name
        handler_name = handler.to_s
        handler_meta = service.respond_to?(:handlers) ? service.handlers[handler_name] : nil
        [svc_name, handler_name, handler_meta]
      else
        [service.to_s, handler.to_s, nil]
      end
    end

    # Resolves a serde value: if the caller passed NOT_SET, fall back to handler metadata, then JsonSerde.
    def resolve_serde(caller_serde, handler_meta, field)
      return caller_serde unless caller_serde.equal?(NOT_SET)

      if handler_meta
        handler_meta.handler_io.public_send(field)
      else
        JsonSerde
      end
    end

    # ── Run execution ──

    def execute_run(handle, action, serde, retry_policy)
      propose_run_result(handle, action, serde, retry_policy)
    end

    # Like execute_run, but offloads the action to a real OS Thread.
    # The fiber yields (via IO.pipe) while the thread runs, keeping the event loop responsive.
    def execute_run_threaded(handle, action, serde, retry_policy)
      propose_run_result(handle, -> { offload_to_thread(action) }, serde, retry_policy)
    end

    # Runs the action and proposes the result (success/failure/transient) to the VM.
    def propose_run_result(handle, action, serde, retry_policy)
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

    # Run a block in an OS thread from a shared pool, yielding the current fiber
    # until it completes. Uses IO.pipe to yield the fiber to the Async event loop
    # while the thread does work.
    #
    # The action is wrapped with a cancellation flag so that if the invocation
    # finishes (e.g., suspended, terminal error) before the pool picks up the job,
    # the action is skipped.
    #
    # Note: With Async 2.x and Ruby 3.1+, the Fiber Scheduler already intercepts
    # most blocking I/O (Net::HTTP, TCPSocket, etc.) and yields the fiber
    # automatically. +background: true+ is only needed for CPU-heavy native
    # extensions that release the GVL (e.g., image processing, crypto).
    def offload_to_thread(action)
      read_io, write_io = IO.pipe
      result = nil
      error = nil
      event = @attempt_finished_event

      begin
        BackgroundPool.submit do
          if event.set?
            # Attempt already finished before pool picked up the job — skip.
            next
          end

          result = action.call
        rescue Exception => e # rubocop:disable Lint/RescueException
          error = e
        ensure
          write_io.close unless write_io.closed?
        end

        # Yields the fiber in Async context; resumes when the worker closes write_io.
        read_io.read(1)
        read_io.close

        raise error if error

        result
      ensure
        read_io.close unless read_io.closed?
        write_io.close unless write_io.closed?
      end
    end

    # A simple fixed-size thread pool for background: true runs.
    # Avoids creating a new Thread per call (~1ms + ~1MB stack each).
    # Workers are daemon threads that do not prevent process exit.
    module BackgroundPool
      @queue = Queue.new
      @workers = []
      @mutex = Mutex.new
      @size = 0

      POOL_SIZE = Integer(ENV.fetch('RESTATE_BACKGROUND_POOL_SIZE', 8))

      module_function

      # Submit a block to be executed by a pool worker.
      def submit(&block)
        ensure_started
        @queue.push(block)
      end

      def ensure_started
        return if @size >= POOL_SIZE

        @mutex.synchronize do
          while @size < POOL_SIZE
            @size += 1
            worker = Thread.new do
              Kernel.loop do
                job = @queue.pop
                break if job == :shutdown

                job.call
              end
            end
            worker.name = "restate-bg-#{@size}"
            # Daemon thread: does not prevent the process from exiting.
            worker.report_on_exception = false
            @workers << worker
          end
        end
      end
    end
  end
end
