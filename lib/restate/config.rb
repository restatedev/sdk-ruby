# typed: true
# frozen_string_literal: true

module Restate
  # Global SDK configuration. Set via +Restate.configure+.
  #
  # @example
  #   Restate.configure do |c|
  #     c.ingress_url = "http://localhost:8080"
  #     c.admin_url   = "http://localhost:9070"
  #   end
  #
  #   # Then use the pre-configured client:
  #   Restate.client.service(Greeter).greet("World")
  class Config
    # Restate ingress URL (for invoking services).
    attr_accessor :ingress_url

    # Restate admin URL (for deployments, invocation management).
    attr_accessor :admin_url

    # Default headers sent with every ingress request.
    attr_accessor :ingress_headers

    # Default headers sent with every admin request.
    attr_accessor :admin_headers

    def initialize
      @ingress_url = 'http://localhost:8080'
      @admin_url = 'http://localhost:9070'
      @ingress_headers = {}
      @admin_headers = {}
    end
  end
end
