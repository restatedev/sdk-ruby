# frozen_string_literal: true

module Restate
  # Raised to indicate a non-retryable failure. Restate will not retry the invocation.
  #
  # @example
  #   raise Restate::TerminalError.new('not found', status_code: 404)
  class TerminalError < StandardError
    attr_reader :status_code

    def initialize(message = 'Internal Server Error', status_code: 500)
      super(message)
      @status_code = status_code
    end
  end

  # Internal: raised when the VM suspends execution.
  # User code should NOT catch this.
  class SuspendedError < StandardError
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
    def initialize
      super(
        "Invocation attempt raised a retryable error.\n" \
        'Restate will retry executing this invocation from the point where it left off.'
      )
    end
  end

  # Internal: raised when the HTTP connection is lost.
  class DisconnectedError < StandardError
    def initialize
      super('Disconnected. The connection to the restate server was lost. Restate will retry the attempt.')
    end
  end
end
