# frozen_string_literal: true

#
# Middleware Example
#
# Demonstrates real OpenTelemetry tracing and tenant isolation middleware
# on a Restate service, including outbound middleware that propagates
# tenant context across service-to-service calls.
#
# Run:
#   bundle install
#   bundle exec falcon serve --bind http://localhost:9080 -n 1
#
# Register:
#   restate deployments register http://localhost:9080
#
# Invoke (watch the console for OTel spans):
#   curl localhost:8080/PaymentService/charge \
#     -H 'content-type: application/json' \
#     -H 'x-tenant-id: acme-corp' \
#     -d '"99.99"'

require_relative 'opentelemetry_middleware'
require_relative 'tenant_middleware'
require_relative 'payment_service'

# Configure OpenTelemetry to export spans to console
OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
      OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter.new
    )
  )
end

# Wire everything together
endpoint = Restate.endpoint(PaymentService, ReceiptService)

# Inbound middleware (wraps handler execution)
endpoint.use(OpenTelemetryMiddleware)
endpoint.use(TenantMiddleware)

# Outbound middleware (wraps outgoing service calls/sends)
endpoint.use_outbound(TenantOutboundMiddleware)

run endpoint.app
