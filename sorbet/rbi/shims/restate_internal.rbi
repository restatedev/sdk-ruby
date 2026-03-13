# typed: true

module Restate
  module Internal
    SDK_VERSION = T.let(T.unsafe(nil), String)
    CANCEL_NOTIFICATION_HANDLE = T.let(T.unsafe(nil), Integer)

    class VMError < RuntimeError; end
    class IdentityKeyError < RuntimeError; end
    class IdentityVerificationError < RuntimeError; end

    class Header
      sig { params(key: String, value: String).void }
      def initialize(key, value); end

      sig { returns(String) }
      def key; end

      sig { returns(String) }
      def value; end
    end

    class ResponseHead
      sig { returns(Integer) }
      def status_code; end

      sig { returns(T::Array[T::Array[String]]) }
      def headers; end
    end

    class Failure
      sig { params(code: Integer, message: String, stacktrace: T.nilable(String)).void }
      def initialize(code, message, stacktrace = nil); end

      sig { returns(Integer) }
      def code; end

      sig { returns(String) }
      def message; end

      sig { returns(T.nilable(String)) }
      def stacktrace; end
    end

    class Void; end
    class Suspended; end

    class StateKeys
      sig { returns(T::Array[String]) }
      def keys; end
    end

    class Input
      sig { returns(String) }
      def invocation_id; end

      sig { returns(Integer) }
      def random_seed; end

      sig { returns(String) }
      def key; end

      sig { returns(T::Array[Header]) }
      def headers; end

      sig { returns(String) }
      def input; end
    end

    class ExponentialRetryConfig
      sig do
        params(
          initial_interval: T.nilable(Integer),
          max_attempts: T.nilable(Integer),
          max_duration: T.nilable(Integer),
          max_interval: T.nilable(Integer),
          factor: T.nilable(Float)
        ).void
      end
      def initialize(initial_interval = nil, max_attempts = nil, max_duration = nil, max_interval = nil,
                     factor = nil); end

      sig { returns(T.nilable(Integer)) }
      def initial_interval; end

      sig { returns(T.nilable(Integer)) }
      def max_attempts; end

      sig { returns(T.nilable(Integer)) }
      def max_duration; end

      sig { returns(T.nilable(Integer)) }
      def max_interval; end

      sig { returns(T.nilable(Float)) }
      def factor; end
    end

    class DoProgressAnyCompleted; end
    class DoProgressReadFromInput; end

    class DoProgressExecuteRun
      sig { returns(Integer) }
      def handle; end
    end

    class DoProgressCancelSignalReceived; end
    class DoWaitForPendingRun; end

    class CallHandle
      sig { returns(Integer) }
      def invocation_id_handle; end

      sig { returns(Integer) }
      def result_handle; end
    end

    class IdentityVerifier
      sig { params(keys: T::Array[String]).void }
      def initialize(keys); end

      sig { params(headers: T::Array[T::Array[String]], path: String).void }
      def verify(headers, path); end
    end

    class VM
      sig { params(headers: T::Array[T::Array[String]]).void }
      def initialize(headers); end

      sig { returns(ResponseHead) }
      def get_response_head; end

      sig { params(buffer: String).void }
      def notify_input(buffer); end

      sig { void }
      def notify_input_closed; end

      sig { params(error: String, stacktrace: T.untyped).void }
      def notify_error(error, stacktrace = nil); end

      sig { returns(T.nilable(String)) }
      def take_output; end

      sig { returns(T::Boolean) }
      def is_ready_to_execute; end

      sig { params(handle: Integer).returns(T::Boolean) }
      def is_completed(handle); end

      sig { params(handles: T::Array[Integer]).returns(T.untyped) }
      def do_progress(handles); end

      sig { params(handle: Integer).returns(T.untyped) }
      def take_notification(handle); end

      sig { returns(Input) }
      def sys_input; end

      sig { params(key: String).returns(Integer) }
      def sys_get_state(key); end

      sig { returns(Integer) }
      def sys_get_state_keys; end

      sig { params(key: String, buffer: String).void }
      def sys_set_state(key, buffer); end

      sig { params(key: String).void }
      def sys_clear_state(key); end

      sig { void }
      def sys_clear_all_state; end

      sig { params(millis: Integer, name: T.nilable(String)).returns(Integer) }
      def sys_sleep(millis, name = nil); end

      sig do
        params(
          service: String,
          handler: String,
          buffer: String,
          key: T.nilable(String),
          idempotency_key: T.nilable(String),
          headers: T.nilable(T::Array[T::Array[String]])
        ).returns(CallHandle)
      end
      def sys_call(service, handler, buffer, key = nil, idempotency_key = nil, headers = nil); end

      sig do
        params(
          service: String,
          handler: String,
          buffer: String,
          key: T.nilable(String),
          delay: T.nilable(Integer),
          idempotency_key: T.nilable(String),
          headers: T.nilable(T::Array[T::Array[String]])
        ).returns(Integer)
      end
      def sys_send(service, handler, buffer, key = nil, delay = nil, idempotency_key = nil, headers = nil); end

      sig { params(name: String).returns(Integer) }
      def sys_run(name); end

      sig { params(handle: Integer, buffer: String).void }
      def propose_run_completion_success(handle, buffer); end

      sig { params(handle: Integer, failure: Failure).void }
      def propose_run_completion_failure(handle, failure); end

      sig do
        params(
          handle: Integer,
          failure: Failure,
          attempt_duration: Integer,
          config: ExponentialRetryConfig
        ).void
      end
      def propose_run_completion_failure_transient(handle, failure, attempt_duration, config); end

      sig { params(buffer: String).void }
      def sys_write_output_success(buffer); end

      sig { params(failure: Failure).void }
      def sys_write_output_failure(failure); end

      sig { void }
      def sys_end; end

      sig { returns(T::Boolean) }
      def is_replaying; end
    end
  end
end
