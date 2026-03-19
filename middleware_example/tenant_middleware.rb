# frozen_string_literal: true

# Extracts tenant ID from invocation headers into fiber-local storage.
#
# The caller sets x-tenant-id in the HTTP header, Restate forwards it
# as an invocation header, and this middleware makes it available to
# handler code via Thread.current[:tenant_id].
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
