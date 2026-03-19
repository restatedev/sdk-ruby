# Middleware Example

Shows how to use Restate handler middleware with real [OpenTelemetry](https://opentelemetry.io/) tracing and tenant isolation.

## What's inside

| File | Description |
|------|-------------|
| `config.ru` | Wiring — configures OTel, creates endpoint, registers middleware |
| `payment_service.rb` | A Restate service that reads tenant from middleware-set context |
| `opentelemetry_middleware.rb` | Creates OTel spans with Restate metadata, extracts W3C TraceContext |
| `tenant_middleware.rb` | Extracts `x-tenant-id` header into fiber-local storage |

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

Middleware follows the [Sidekiq middleware](https://github.com/sidekiq/sidekiq/wiki/Middleware) pattern — a class with a `call` method that uses `yield`:

```ruby
class MyMiddleware
  def call(handler, ctx)
    # before — handler.name, handler.service_tag.name, ctx.request.id, ctx.request.headers
    result = yield
    # after
    result
  end
end

endpoint = Restate.endpoint(MyService)
endpoint.use(MyMiddleware)
```

Middleware executes in registration order. Each middleware wraps the next, forming an onion around the handler.
