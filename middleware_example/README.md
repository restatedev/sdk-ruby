# Middleware Example

Shows how to use Restate handler middleware with real [OpenTelemetry](https://opentelemetry.io/) tracing and tenant isolation — including outbound middleware that propagates context across service-to-service calls.

## What's inside

| File | Description |
|------|-------------|
| `config.ru` | Wiring — configures OTel, creates endpoint, registers inbound + outbound middleware |
| `payment_service.rb` | PaymentService charges and calls ReceiptService; ReceiptService reads tenant from headers |
| `opentelemetry_middleware.rb` | Inbound: creates OTel spans with Restate metadata, extracts W3C TraceContext |
| `tenant_middleware.rb` | Inbound: extracts `x-tenant-id` into fiber-local storage. Outbound: injects it into outgoing calls |

## Running

```shell
bundle install
bundle exec falcon serve --bind http://localhost:9080 -n 1
```

Register with Restate:

```shell
restate deployments register http://localhost:9080
```

Invoke (watch the console for OTel spans):

```shell
curl localhost:8080/PaymentService/charge \
  -H 'content-type: application/json' \
  -H 'x-tenant-id: acme-corp' \
  -d '"99.99"'
```

## How middleware works

### Inbound (server) middleware

Inbound middleware wraps handler execution, following the [Sidekiq server middleware](https://github.com/sidekiq/sidekiq/wiki/Middleware) pattern:

```ruby
class MyMiddleware
  def call(handler, ctx)
    # before — handler.name, handler.service_tag.name, ctx.request.id, ctx.request.headers
    result = yield
    # after
    result
  end
end

endpoint.use(MyMiddleware)
```

### Outbound (client) middleware

Outbound middleware wraps every outgoing service call/send, following the [Sidekiq client middleware](https://github.com/sidekiq/sidekiq/wiki/Middleware) pattern:

```ruby
class MyOutboundMiddleware
  def call(service, handler, headers)
    headers['x-custom'] = 'value'
    yield
  end
end

endpoint.use_outbound(MyOutboundMiddleware)
```

Middleware executes in registration order. Each middleware wraps the next, forming an onion around the handler (inbound) or the outgoing call (outbound).
