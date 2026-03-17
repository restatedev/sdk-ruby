# typed: true
# frozen_string_literal: true

begin
  # Cross-compiled native gems place the binary in a version-specific directory
  # e.g., lib/restate/3.3/restate_internal.bundle
  RUBY_VERSION =~ /(\d+\.\d+)/
  require_relative "#{Regexp.last_match(1)}/restate_internal"
rescue LoadError
  # Fall back to the default location (development builds, source gem installs)
  require_relative 'restate_internal'
end

module Restate
  # Ruby-side data types for VM results
  Invocation = Struct.new(:invocation_id, :random_seed, :headers, :input_buffer, :key, keyword_init: true)
  Failure = Struct.new(:code, :message, :stacktrace, keyword_init: true)

  class NotReady; end
  class Suspended; end

  NOT_READY = T.let(NotReady.new.freeze, NotReady)
  SUSPENDED = T.let(Suspended.new.freeze, Suspended)
  CANCEL_HANDLE = T.let(Internal::CANCEL_NOTIFICATION_HANDLE, Integer)

  # Progress loop result types
  class DoProgressAnyCompleted; end
  class DoProgressReadFromInput; end
  class DoProgressCancelSignalReceived; end
  class DoWaitPendingRun; end

  DO_PROGRESS_ANY_COMPLETED = T.let(DoProgressAnyCompleted.new.freeze, DoProgressAnyCompleted)
  DO_PROGRESS_READ_FROM_INPUT = T.let(DoProgressReadFromInput.new.freeze, DoProgressReadFromInput)
  DO_PROGRESS_CANCEL_SIGNAL_RECEIVED = T.let(DoProgressCancelSignalReceived.new.freeze, DoProgressCancelSignalReceived)
  DO_WAIT_PENDING_RUN = T.let(DoWaitPendingRun.new.freeze, DoWaitPendingRun)

  DoProgressExecuteRun = Struct.new(:handle, keyword_init: true)

  # User-facing retry policy for ctx.run
  RunRetryPolicy = Struct.new(
    :initial_interval, :max_attempts, :max_duration,
    :max_interval, :interval_factor,
    keyword_init: true
  )

  # Exponential retry configuration for run
  RunRetryConfig = Struct.new(
    :initial_interval, :max_attempts, :max_duration,
    :max_interval, :interval_factor,
    keyword_init: true
  )

  # Wraps the native Restate::Internal::VM, mapping native types to Ruby types.
  class VMWrapper
    extend T::Sig

    sig { params(headers: T.untyped).void }
    def initialize(headers)
      @vm = T.let(Internal::VM.new(headers), Internal::VM)
    end

    sig { returns([Integer, T.untyped]) }
    def get_response_head
      result = @vm.get_response_head
      [result.status_code, result.headers]
    end

    sig { params(buf: String).void }
    def notify_input(buf)
      @vm.notify_input(buf)
    end

    sig { void }
    def notify_input_closed
      @vm.notify_input_closed
    end

    sig { params(error: String, stacktrace: T.nilable(String)).void }
    def notify_error(error, stacktrace = nil)
      @vm.notify_error(error, stacktrace)
    end

    sig { returns(T.nilable(String)) }
    def take_output
      @vm.take_output
    end

    sig { returns(T::Boolean) }
    def is_ready_to_execute
      @vm.is_ready_to_execute
    end

    sig { params(handle: Integer).returns(T::Boolean) }
    def is_completed(handle)
      @vm.is_completed(handle)
    end

    sig { params(handles: T::Array[Integer]).returns(T.untyped) }
    def do_progress(handles)
      result = @vm.do_progress(handles)
      map_do_progress(result)
    rescue Internal::VMError => e
      e
    end

    sig { params(handle: Integer).returns(T.untyped) }
    def take_notification(handle)
      result = @vm.take_notification(handle)
      map_notification(result)
    rescue Internal::VMError => e
      e
    end

    sig { returns(T.untyped) }
    def sys_input
      inp = @vm.sys_input
      headers = inp.headers.map { |h| [h.key, h.value] }
      Invocation.new(
        invocation_id: inp.invocation_id,
        random_seed: inp.random_seed,
        headers: headers,
        input_buffer: inp.input.b,
        key: inp.key
      )
    end

    sig { params(name: String).returns(Integer) }
    def sys_get_state(name)
      @vm.sys_get_state(name)
    end

    sig { returns(Integer) }
    def sys_get_state_keys
      @vm.sys_get_state_keys
    end

    sig { params(name: String, value: String).void }
    def sys_set_state(name, value)
      @vm.sys_set_state(name, value)
    end

    sig { params(name: String).void }
    def sys_clear_state(name)
      @vm.sys_clear_state(name)
    end

    sig { void }
    def sys_clear_all_state
      @vm.sys_clear_all_state
    end

    sig { params(millis: Integer, name: T.nilable(String)).returns(Integer) }
    def sys_sleep(millis, name = nil)
      # Rust side always expects 2 args: (millis, name_or_nil)
      @vm.sys_sleep(millis, name)
    end

    sig do
      params(
        service: String,
        handler: String,
        parameter: String,
        key: T.nilable(String),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(Internal::CallHandle)
    end
    def sys_call(service:, handler:, parameter:, key: nil, idempotency_key: nil, headers: nil)
      # Rust side expects 6 args: (service, handler, buffer, key_or_nil, idem_key_or_nil, headers_or_nil)
      hdr_array = headers&.map { |k, v| [k, v] }
      @vm.sys_call(service, handler, parameter, key, idempotency_key, hdr_array)
    end

    sig do
      params(
        service: String,
        handler: String,
        parameter: String,
        key: T.nilable(String),
        delay: T.nilable(Integer),
        idempotency_key: T.nilable(String),
        headers: T.nilable(T::Hash[String, String])
      ).returns(Integer)
    end
    def sys_send(service:, handler:, parameter:, key: nil, delay: nil, idempotency_key: nil, headers: nil)
      # Rust side expects 7 args
      hdr_array = headers&.map { |k, v| [k, v] }
      @vm.sys_send(service, handler, parameter, key, delay, idempotency_key, hdr_array)
    end

    sig { params(name: String).returns(Integer) }
    def sys_run(name)
      @vm.sys_run(name)
    end

    sig { params(handle: Integer, output: String).void }
    def propose_run_completion_success(handle, output)
      @vm.propose_run_completion_success(handle, output)
    end

    sig { params(handle: Integer, failure: T.untyped).void }
    def propose_run_completion_failure(handle, failure)
      native_failure = Internal::Failure.new(failure.code, failure.message, nil)
      @vm.propose_run_completion_failure(handle, native_failure)
    end

    sig do
      params(
        handle: Integer,
        failure: T.untyped,
        attempt_duration_ms: Integer,
        config: T.untyped
      ).void
    end
    def propose_run_completion_transient(handle, failure:, attempt_duration_ms:, config:)
      native_failure = Internal::Failure.new(failure.code, failure.message, failure.stacktrace)
      native_config = Internal::ExponentialRetryConfig.new(
        config.initial_interval, config.max_attempts,
        config.max_duration, config.max_interval,
        config.interval_factor
      )
      @vm.propose_run_completion_failure_transient(handle, native_failure, attempt_duration_ms, native_config)
    end

    sig { params(output: String).void }
    def sys_write_output_success(output)
      @vm.sys_write_output_success(output)
    end

    sig { params(failure: T.untyped).void }
    def sys_write_output_failure(failure)
      native_failure = Internal::Failure.new(failure.code, failure.message, nil)
      @vm.sys_write_output_failure(native_failure)
    end

    sig { void }
    def sys_end
      @vm.sys_end
    end

    sig { returns(T::Boolean) }
    def is_replaying
      @vm.is_replaying
    end

    # Returns [awakeable_id (String), notification_handle (Integer)]
    sig { returns([String, Integer]) }
    def sys_awakeable
      @vm.sys_awakeable
    end

    sig { params(awakeable_id: String, value: String).void }
    def sys_complete_awakeable_success(awakeable_id, value)
      @vm.sys_complete_awakeable_success(awakeable_id, value)
    end

    sig { params(awakeable_id: String, failure: T.untyped).void }
    def sys_complete_awakeable_failure(awakeable_id, failure)
      native_failure = Internal::Failure.new(failure.code, failure.message, nil)
      @vm.sys_complete_awakeable_failure(awakeable_id, native_failure)
    end

    sig { params(key: String).returns(Integer) }
    def sys_get_promise(key)
      @vm.sys_get_promise(key)
    end

    sig { params(key: String).returns(Integer) }
    def sys_peek_promise(key)
      @vm.sys_peek_promise(key)
    end

    sig { params(key: String, value: String).returns(Integer) }
    def sys_complete_promise_success(key, value)
      @vm.sys_complete_promise_success(key, value)
    end

    sig { params(key: String, failure: T.untyped).returns(Integer) }
    def sys_complete_promise_failure(key, failure)
      native_failure = Internal::Failure.new(failure.code, failure.message, nil)
      @vm.sys_complete_promise_failure(key, native_failure)
    end

    sig { params(invocation_id: String).void }
    def sys_cancel_invocation(invocation_id)
      @vm.sys_cancel_invocation(invocation_id)
    end

    private

    sig { params(result: T.untyped).returns(T.untyped) }
    def map_do_progress(result)
      case result
      when Internal::Suspended
        SUSPENDED
      when Internal::DoProgressAnyCompleted
        DO_PROGRESS_ANY_COMPLETED
      when Internal::DoProgressReadFromInput
        DO_PROGRESS_READ_FROM_INPUT
      when Internal::DoProgressExecuteRun
        DoProgressExecuteRun.new(handle: result.handle)
      when Internal::DoProgressCancelSignalReceived
        DO_PROGRESS_CANCEL_SIGNAL_RECEIVED
      when Internal::DoWaitForPendingRun
        DO_WAIT_PENDING_RUN
      else
        raise "Unknown progress type: #{result.class}"
      end
    end

    sig { params(result: T.untyped).returns(T.untyped) }
    def map_notification(result)
      case result
      when Internal::Suspended
        SUSPENDED
      when NilClass
        NOT_READY
      when Internal::Void
        nil
      when String
        # Could be bytes (success) or invocation_id string.
        # The native layer returns RString for both.
        result
      when Internal::Failure
        Failure.new(code: result.code, message: result.message)
      when Internal::StateKeys
        result.keys
      else
        raise "Unknown notification type: #{result.class}"
      end
    end
  end
end
