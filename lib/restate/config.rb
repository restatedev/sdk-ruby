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
    # Can be a Hash or a callable (Proc/Lambda) returning a Hash.
    # A callable is evaluated each time +Restate.client+ is called,
    # which lets frameworks like Rails inject per-request context
    # (e.g., team ID, shard routing, auth tokens).
    #
    # @example Static headers
    #   config.ingress_headers = { "Authorization" => "Bearer tok" }
    #
    # @example Dynamic headers
    #   config.ingress_headers = -> { { "X-Team-Id" => Current.team_id } }
    attr_accessor :ingress_headers

    # Default headers sent with every admin request.
    # Accepts the same static Hash or callable forms as +ingress_headers+.
    attr_accessor :admin_headers

    def initialize
      @ingress_url = 'http://localhost:8080'
      @admin_url = 'http://localhost:9070'
      @ingress_headers = {}
      @admin_headers = {}
    end
  end
end
