# typed: true
# frozen_string_literal: true

require 'json'

module Restate
  module Discovery
    extend T::Sig

    PROTOCOL_MODES = T.let({
      'bidi' => 'BIDI_STREAM',
      'request_response' => 'REQUEST_RESPONSE'
    }.freeze, T::Hash[String, String])

    SERVICE_TYPES = T.let({
      'service' => 'SERVICE',
      'object' => 'VIRTUAL_OBJECT',
      'workflow' => 'WORKFLOW'
    }.freeze, T::Hash[String, String])

    HANDLER_TYPES = T.let({
      'exclusive' => 'EXCLUSIVE',
      'shared' => 'SHARED',
      'workflow' => 'WORKFLOW'
    }.freeze, T::Hash[String, String])

    module_function

    # Generate the discovery JSON for the given endpoint.
    sig { params(endpoint: Endpoint, _version: Integer, discovered_as: String).returns(String) }
    def compute_discovery_json(endpoint, _version, discovered_as)
      ep = compute_discovery(endpoint, discovered_as)
      JSON.generate(ep, allow_nan: false)
    end

    # Build the discovery hash for the endpoint.
    sig { params(endpoint: Endpoint, discovered_as: String).returns(T::Hash[Symbol, T.untyped]) }
    def compute_discovery(endpoint, discovered_as)
      services = endpoint.services.values.map do |service|
        build_service(service)
      end

      protocol_mode = PROTOCOL_MODES.fetch(endpoint.protocol || discovered_as)

      compact({
                protocolMode: protocol_mode,
                minProtocolVersion: 5,
                maxProtocolVersion: 5,
                services: services
              })
    end

    sig { params(service: T.any(Service, VirtualObject, Workflow)).returns(T::Hash[Symbol, T.untyped]) }
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

    sig { params(handler: T.untyped).returns(T::Hash[Symbol, T.untyped]) }
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
    sig { params(hash: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def compact(hash)
      hash.each_with_object({}) do |(k, v), result|
        next if v.nil?

        result[k] = v.is_a?(Hash) ? compact(v) : v
      end
    end
  end
end
