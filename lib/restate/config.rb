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
    extend T::Sig

    # Restate ingress URL (for invoking services).
    sig { returns(String) }
    attr_accessor :ingress_url

    # Restate admin URL (for deployments, invocation management).
    sig { returns(String) }
    attr_accessor :admin_url

    # Default headers sent with every ingress request.
    sig { returns(T::Hash[String, String]) }
    attr_accessor :ingress_headers

    # Default headers sent with every admin request.
    sig { returns(T::Hash[String, String]) }
    attr_accessor :admin_headers

    sig { void }
    def initialize
      @ingress_url = T.let('http://localhost:8080', String)
      @admin_url = T.let('http://localhost:9070', String)
      @ingress_headers = T.let({}, T::Hash[String, String])
      @admin_headers = T.let({}, T::Hash[String, String])
    end
  end
end
