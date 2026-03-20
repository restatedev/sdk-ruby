# typed: true

# Shim for the native Rust extension (ext/restate_internal/).
# These classes/methods are defined in Rust via Magnus and not visible to Sorbet.

module Restate
  module Internal
    CANCEL_NOTIFICATION_HANDLE = T.let(0, Integer)

    class VM
      def initialize(headers:, input:); end
      def notify_input(bytes); end
      def notify_input_closed; end
      def is_ready_to_execute?; end
      def sys_input; end
      def do_progress(handles); end
      def take_output; end
      def take_notification(handle); end
      def is_completed(handle); end
      def sys_get_state(name); end
      def sys_get_state_keys; end
      def sys_set_state(name, value); end
      def sys_clear_state(name); end
      def sys_clear_all_state; end
      def sys_sleep(millis); end
      def sys_run(name); end
      def sys_call(service:, handler:, parameter:, key:, idempotency_key:, headers:); end
      def sys_send(service:, handler:, parameter:, key:, delay:, idempotency_key:, headers:); end
      def sys_awakeable; end
      def sys_complete_awakeable_success(id, value); end
      def sys_complete_awakeable_failure(id, failure); end
      def sys_get_promise(name); end
      def sys_peek_promise(name); end
      def sys_complete_promise_success(name, value); end
      def sys_complete_promise_failure(name, failure); end
      def sys_cancel_invocation(id); end
      def sys_write_output_success(bytes); end
      def sys_write_output_failure(failure); end
      def sys_end; end
      def notify_error(message, stacktrace); end
      def propose_run_completion_success(handle, value); end
      def propose_run_completion_failure(handle, failure); end
      def propose_run_completion_transient(handle, failure:, attempt_duration_ms:, config:); end
      def is_replaying; end
    end

    class IdentityVerifier
      def initialize(keys); end
      def verify(path, headers); end
    end
  end

  # VM wrapper result types (defined in Ruby in vm.rb but referenced as bare constants
  # from the native extension which Sorbet can't see through)
  class VMError < StandardError; end
  class Failure; end
  class ExponentialRetryConfig; end
  class StateKeys; end
  class Void; end
  class Suspended; end
  class DoProgressAnyCompleted; end
  class DoProgressReadFromInput; end
  class DoProgressExecuteRun; end
  class DoProgressCancelSignalReceived; end
  class DoWaitForPendingRun; end

  # Additional types referenced by server_context.rb and endpoint.rb
  class NotReady; end
  class DoWaitPendingRun; end
  class RunRetryConfig; end
  class Server
    def initialize(endpoint); end
  end

  # Server-level types
  class IdentityVerificationError < StandardError; end
  SDK_VERSION = T.let('', String)
end
