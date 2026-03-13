# typed: strict
# frozen_string_literal: true

module Restate
  # Raised to indicate that Restate should not retry this invocation.
  class TerminalError < StandardError
    extend T::Sig

    sig { returns(Integer) }
    attr_reader :status_code

    sig { params(message: String, status_code: Integer).void }
    def initialize(message = 'Internal Server Error', status_code: 500)
      super(message)
      @status_code = T.let(status_code, Integer)
    end
  end

  # Internal: raised when the VM suspends execution.
  # User code should NOT catch this.
  class SuspendedError < StandardError
    extend T::Sig

    sig { void }
    def initialize
      super(
        "Invocation got suspended, Restate will resume this invocation when progress can be made.\n" \
        "This exception is safe to ignore. If you see it, you might be using a bare rescue.\n\n" \
        "Don't do:\nbegin\n  # Code\nrescue => e\n  # This catches SuspendedError!\nend\n\n" \
        "Do instead:\nbegin\n  # Code\nrescue Restate::TerminalError => e\n  # Handle terminal errors\nend"
      )
    end
  end

  # Internal: raised when the VM encounters a retryable error.
  class InternalError < StandardError
    extend T::Sig

    sig { void }
    def initialize
      super(
        "Invocation attempt raised a retryable error.\n" \
        'Restate will retry executing this invocation from the point where it left off.'
      )
    end
  end

  # Internal: raised when the HTTP connection is lost.
  class DisconnectedError < StandardError
    extend T::Sig

    sig { void }
    def initialize
      super('Disconnected. The connection to the restate server was lost. Restate will retry the attempt.')
    end
  end
end
