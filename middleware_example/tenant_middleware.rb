# frozen_string_literal: true

# Inbound: extracts tenant ID from invocation headers into fiber-local storage.
#
# The caller sets x-tenant-id in the HTTP header, Restate forwards it
# as an invocation header, and this middleware makes it available to
# handler code via Thread.current[:tenant_id] (fiber-scoped in Ruby 3.0+).
#
# Register with: endpoint.use(TenantMiddleware)
class TenantMiddleware
  # @param _handler [Restate::Handler]
  # @param ctx [Restate::Context]
  def call(_handler, ctx)
    Thread.current[:tenant_id] = ctx.request.headers['x-tenant-id']
    yield
  ensure
    Thread.current[:tenant_id] = nil
  end
end

# Outbound: injects the current tenant ID into every outgoing service call/send.
#
# This ensures that when a handler calls another service, the tenant context
# propagates automatically — without manually passing headers: at every call site.
#
# Register with: endpoint.use_outbound(TenantOutboundMiddleware)
class TenantOutboundMiddleware
  def call(_service, _handler, headers)
    tenant = Thread.current[:tenant_id]
    headers['x-tenant-id'] = tenant if tenant
    yield
  end
end
