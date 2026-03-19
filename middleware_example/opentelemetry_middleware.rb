# frozen_string_literal: true

require 'opentelemetry-sdk'

# Handler-level OpenTelemetry tracing middleware for Restate.
#
# Creates a span for every handler invocation with Restate-specific
# attributes. Extracts W3C TraceContext from invocation headers so
# traces propagate across service-to-service calls.
#
# Follows the same pattern as opentelemetry-instrumentation-sidekiq:
# https://github.com/open-telemetry/opentelemetry-ruby-contrib/tree/main/
#   instrumentation/sidekiq
class OpenTelemetryMiddleware
  TRACER = OpenTelemetry.tracer_provider.tracer('restate-sdk', '0.1.0')

  # @param handler [Restate::Handler]
  # @param ctx [Restate::Context]
  def call(handler, ctx)
    attributes = {
      'restate.service' => handler.service_tag.name,
      'restate.handler' => handler.name,
      'restate.handler.kind' => handler.kind || 'stateless',
      'restate.invocation_id' => ctx.request.id
    }

    extracted_context = OpenTelemetry.propagation.extract(ctx.request.headers)

    OpenTelemetry::Context.with_current(extracted_context) do
      TRACER.in_span("#{handler.service_tag.name}/#{handler.name}",
                     attributes: attributes, kind: :consumer) do |span|
        result = yield
        span.set_attribute('restate.status', 'ok')
        result
      end
    end
  end
end
