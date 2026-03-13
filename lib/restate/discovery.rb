# frozen_string_literal: true

require "json"

module Restate
  module Discovery
    PROTOCOL_MODES = {
      "bidi" => "BIDI_STREAM",
      "request_response" => "REQUEST_RESPONSE"
    }.freeze

    SERVICE_TYPES = {
      "service" => "SERVICE",
      "object" => "VIRTUAL_OBJECT",
      "workflow" => "WORKFLOW"
    }.freeze

    HANDLER_TYPES = {
      "exclusive" => "EXCLUSIVE",
      "shared" => "SHARED",
      "workflow" => "WORKFLOW"
    }.freeze

    module_function

    # Generate the discovery JSON for the given endpoint.
    #
    # @param endpoint [Restate::Endpoint] the endpoint to discover
    # @param version [Integer] protocol version (2, 3, or 4)
    # @param discovered_as [String] "bidi" or "request_response"
    # @return [String] JSON string
    def compute_discovery_json(endpoint, version, discovered_as)
      ep = compute_discovery(endpoint, discovered_as)
      JSON.generate(ep, allow_nan: false)
    end

    # Build the discovery hash for the endpoint.
    def compute_discovery(endpoint, discovered_as)
      services = endpoint.services.values.map do |service|
        build_service(service)
      end

      protocol_mode = if endpoint.protocol
                        PROTOCOL_MODES.fetch(endpoint.protocol)
                      else
                        PROTOCOL_MODES.fetch(discovered_as)
                      end

      compact({
        protocolMode: protocol_mode,
        minProtocolVersion: 5,
        maxProtocolVersion: 5,
        services: services
      })
    end

    def build_service(service)
      service_type = SERVICE_TYPES.fetch(service.service_tag.kind)

      handlers = service.handlers.values.map do |handler|
        build_handler(handler)
      end

      compact({
        name: service.name,
        ty: service_type,
        handlers: handlers,
        documentation: service.service_tag.description,
        metadata: service.service_tag.metadata
      })
    end

    def build_handler(handler)
      ty = handler.kind ? HANDLER_TYPES.fetch(handler.kind) : nil

      input_payload = {
        required: false,
        contentType: handler.handler_io.accept
      }

      output_payload = {
        setContentTypeIfEmpty: false,
        contentType: handler.handler_io.content_type
      }

      compact({
        name: handler.name,
        ty: ty,
        input: compact(input_payload),
        output: compact(output_payload)
      })
    end

    # Remove nil values from a hash (non-recursive for top level, recursive for nested).
    def compact(hash)
      hash.each_with_object({}) do |(k, v), result|
        next if v.nil?

        result[k] = v.is_a?(Hash) ? compact(v) : v
      end
    end
  end
end
