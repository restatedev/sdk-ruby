# Restate Ruby SDK — User Guide

Build resilient applications with durable execution in Ruby. The Restate Ruby SDK lets you
write handlers that survive crashes, retries, and infrastructure failures — with the simplicity
of ordinary Ruby code.

---

## Quick Start

### 1. Define a Service

```ruby
# greeter.rb
require 'restate'

class Greeter < Restate::Service
  handler def greet(name)
    Restate.run_sync('build-greeting') { "Hello, #{name}!" }
  end
end

endpoint = Restate.endpoint(Greeter)
```

### 2. Create a Rackup File

```ruby
# config.ru
require_relative 'greeter'
run endpoint.app
```

### 3. Run with Falcon

```bash
bundle exec falcon serve --bind http://localhost:9080
```

### 4. Register with Restate and Invoke

```bash
restate deployments register http://localhost:9080
curl localhost:8080/Greeter/greet -H 'content-type: application/json' -d '"World"'
# → "Hello, World!"
```

---

## Service Types

The SDK provides three service types, each with different durability and concurrency guarantees.

### Service (Stateless)

Stateless handlers that can be invoked by name. Each invocation is independent.

```ruby
class MyService < Restate::Service
  handler def my_handler(input)
    # input is the deserialized JSON body
    # return value is serialized as the JSON response
    { 'result' => input }
  end
end
```

**Invoke**: `POST /MyService/my_handler`

### VirtualObject (Keyed, Stateful)

Each virtual object instance is identified by a key and has durable K/V state scoped to that key.

```ruby
class Counter < Restate::VirtualObject
  state :count, default: 0    # Declarative state with auto-generated accessors

  handler def add(amount)
    self.count += amount       # Reads via Restate.get, writes via Restate.set
  end

  shared def get
    count                      # Returns 0 when unset (the default)
  end
end
```

You can also use `Restate.get`/`Restate.set` directly — see [State Operations](#state-operations).

**Invoke**: `POST /Counter/my-counter/add` (key is `my-counter`)

### Workflow (Durable, Run-Once)

A workflow's `main` handler runs exactly once per key. Shared handlers let external callers
query state and send signals.

```ruby
class UserSignup < Restate::Workflow
  main def run(email)
    user_id = Restate.run_sync('create-account') { create_user(email) }
    Restate.set('status', 'waiting_for_approval')

    # Block until approve() is called
    approval = Restate.promise('approval')
    Restate.set('status', 'active')
    { 'user_id' => user_id, 'approval' => approval }
  end

  handler def approve(reason)
    Restate.resolve_promise('approval', reason)
  end

  handler def status
    Restate.get('status') || 'unknown'
  end
end
```

**Invoke**:
```bash
curl localhost:8080/UserSignup/user42/run -d '"user@example.com"'
curl localhost:8080/UserSignup/user42/approve -d '"approved by admin"'
curl localhost:8080/UserSignup/user42/status -d 'null'
```

---

## Context API Reference

All Restate operations are available as top-level module methods on `Restate`. Inside a handler,
call `Restate.run_sync`, `Restate.sleep`, `Restate.get`, etc. directly:

```ruby
handler def greet(name)
  Restate.run_sync('step') { ... }
end
```

All operations that interact with Restate return durable results — if the handler crashes and
retries, completed operations are replayed from the journal without re-executing.

### Durable Execution (`Restate.run`)

Execute a side effect exactly once. The result is durably recorded — on retry, the block is
skipped and the stored result is returned.

`run` returns a `DurableFuture`; call `.await` to get the result. Use `run_sync` to get
the value directly:

```ruby
# Returns a future — useful for fan-out (see below)
future = Restate.run('step-name') { do_something() }
result = future.await

# Returns the value directly — convenient for sequential steps
result = Restate.run_sync('step-name') { do_something() }
```

**With retry policy:**
```ruby
policy = Restate::RunRetryPolicy.new(
  initial_interval: 100,     # ms between retries
  max_attempts: 5,           # max retry count
  interval_factor: 2.0,      # exponential backoff multiplier
  max_interval: 10_000,      # ms cap on retry interval
  max_duration: 60_000       # ms total duration cap
)

result = Restate.run_sync('flaky-call', retry_policy: policy) { call_external_api() }
```

**Terminal errors** (non-retryable):
```ruby
Restate.run_sync('validate') do
  raise Restate::TerminalError.new('invalid input', status_code: 400)
end
```

**Background thread** (`background: true`):

**Background thread pool** (`background: true`):

With Async and Ruby 3.1+, the Fiber Scheduler automatically intercepts most blocking I/O
(`Net::HTTP`, `TCPSocket`, file I/O, etc.) and yields the fiber — so `run` already handles
I/O-bound work without blocking the event loop.

Pass `background: true` only for **CPU-heavy native extensions that release the GVL** (e.g.,
image processing, crypto). The block runs in a shared thread pool (default 8 workers,
configurable via `RESTATE_BACKGROUND_POOL_SIZE`):

```ruby
result = Restate.run_sync('resize-image', background: true) { process_image(data) }
```

### Declarative State

The `state` macro declares durable state entries on VirtualObject and Workflow classes. It generates
getter, setter, and clear methods that delegate to the context automatically.

```ruby
class Counter < Restate::VirtualObject
  state :count, default: 0

  handler def add(addend)
    self.count += addend     # getter reads Restate.get('count'), setter calls Restate.set('count', ...)
  end

  shared def get
    count                    # returns 0 when state is unset
  end

  handler def reset
    clear_count              # removes the state entry
  end
end
```

**Options:**
- `default:` — value returned when the state entry hasn't been set (default: `nil`)
- `serde:` — custom serializer/deserializer (default: `JsonSerde`)

**Note:** State names must differ from handler names, since both generate instance methods on
the same class. If you need the same name, use `Restate.get`/`Restate.set` directly.

### State Operations

You can also manage state explicitly via the `Restate` module methods. Available in `VirtualObject`
and `Workflow` handlers.

```ruby
value = Restate.get('key')              # Read state (nil if absent)
Restate.set('key', value)               # Write state
Restate.clear('key')                    # Delete one key
Restate.clear_all                       # Delete all keys
keys = Restate.state_keys               # List all key names
```

**Async variants** — return a `DurableFuture` instead of blocking, useful for fan-out:

```ruby
future_a = Restate.get_async('key_a')
future_b = Restate.get_async('key_b')
keys_future = Restate.state_keys_async

# Await results (fetches happen concurrently)
val_a = future_a.await
val_b = future_b.await
keys = keys_future.await
```

Values are JSON-serialized by default. Pass `serde:` for custom serialization:

```ruby
Restate.get('key', serde: Restate::BytesSerde)
Restate.get_async('key', serde: Restate::BytesSerde)
Restate.set('key', raw_bytes, serde: Restate::BytesSerde)
```

### Sleep

```ruby
Restate.sleep(5.0).await                # Sleep for 5 seconds (durable timer)
```

The timer survives crashes — if the handler restarts, it resumes waiting for the remaining time.

### Service Communication

#### Fluent Call API (Recommended)

The fluent API reads like natural Ruby — call handlers directly on service classes:

```ruby
# Durable calls (return DurableCallFuture)
result = Worker.call.process(task).await              # Service
result = Counter.call("my-key").add(5).await          # VirtualObject
result = UserSignup.call("user42").run(email).await   # Workflow

# Fire-and-forget sends (return SendHandle)
Worker.send!.process(task)                            # Service
Counter.send!("my-key").add(5)                        # VirtualObject
Worker.send!(delay: 60).process('cleanup')            # Delayed send
```

Under the hood this delegates to `Restate.service_call`/`Restate.object_call`/etc. — the fluent API
is pure syntactic sugar with no behavior difference.

#### Explicit Calls

For full control over options (idempotency keys, custom headers, serde overrides), use the
`Restate` module methods directly:

```ruby
# Typed call (resolves serdes from target handler registration)
result = Restate.service_call(MyService, :my_handler, arg).await
result = Restate.object_call(Counter, :add, 'my-key', 5).await
result = Restate.workflow_call(UserSignup, :run, 'user42', email).await

# String-based call (uses JsonSerde)
result = Restate.service_call('MyService', 'my_handler', arg).await
```

**DurableCallFuture methods:**
```ruby
future = Restate.service_call(MyService, :handler, arg)
result = future.await                # Block until result
id = future.invocation_id            # Get invocation ID
future.cancel                        # Cancel the remote invocation
```

#### Fire-and-Forget Sends

Dispatch a call without waiting for the result.

```ruby
handle = Restate.service_send(MyService, :handler, arg)
handle = Restate.object_send(Counter, :add, 'my-key', 5)

# Delayed send (executes after 60 seconds)
handle = Restate.service_send(MyService, :handler, arg, delay: 60.0)
```

**SendHandle methods:**
```ruby
id = handle.invocation_id            # Get invocation ID
handle.cancel                        # Cancel the invocation
```

#### Call Options

All call/send methods — both fluent and explicit — accept these keyword arguments:

```ruby
# Fluent API — kwargs pass through to the underlying call
Worker.call.process(task, idempotency_key: 'unique-key').await
Counter.call("key").add(5, headers: { 'x-trace' => 'abc' }).await
Worker.send!.process(task, idempotency_key: 'dedup-key')

# Explicit API — same kwargs
Restate.service_call(
  MyService, :handler, arg,
  idempotency_key: 'unique-key',     # Deduplication key
  headers: { 'x-custom' => 'val' },  # Custom headers
  input_serde: MyCustomSerde,        # Override input serializer
  output_serde: MyCustomSerde        # Override output serializer
)
```

| Option | Call | Send | Description |
|--------|:---:|:---:|-------------|
| `idempotency_key:` | yes | yes | Deduplication key for exactly-once semantics |
| `headers:` | yes | yes | Custom headers forwarded to the target handler |
| `input_serde:` | yes | yes | Override input serializer |
| `output_serde:` | yes | — | Override output serializer |

### Fan-Out / Fan-In

Launch multiple calls concurrently, then collect all results.

```ruby
# Fan-out: launch calls
futures = tasks.map { |t| Restate.service_call(Worker, :process, t) }

# Fan-in: await all
results = futures.map(&:await)
```

### Wait Any (Racing Futures)

Wait for the first future to complete out of several.

```ruby
future_a = Restate.service_call(ServiceA, :slow, arg)
future_b = Restate.service_call(ServiceB, :fast, arg)

completed, remaining = Restate.wait_any(future_a, future_b)
winner = completed.first.await
```

### Awakeables (External Callbacks)

Pause a handler until an external system calls back via Restate's API.

```ruby
# In your handler: create an awakeable
awakeable_id, future = Restate.awakeable

# Send the ID to an external system
Restate.run_sync('notify') { send_to_external_system(awakeable_id) }

# Block until the external system resolves it
result = future.await
```

The external system resolves the awakeable via Restate's HTTP API:
```bash
curl -X POST http://restate:8080/restate/awakeables/$AWAKEABLE_ID/resolve \
  -H 'content-type: application/json' -d '"callback data"'
```

**From another handler:**
```ruby
Restate.resolve_awakeable(awakeable_id, payload)
Restate.reject_awakeable(awakeable_id, 'reason', code: 500)
```

### Promises (Workflow Only)

Durable promises allow communication between a workflow's main handler and its signal handlers.

```ruby
# In main handler: block until promise is resolved
value = Restate.promise('approval')

# In signal handler: resolve the promise
Restate.resolve_promise('approval', value)

# Non-blocking peek (returns nil if not yet resolved)
value = Restate.peek_promise('approval')

# Reject a promise
Restate.reject_promise('approval', 'denied', code: 400)
```

### Request Metadata

```ruby
request = Restate.request
request.id         # Invocation ID (String)
request.headers    # Request headers (Hash)
request.body       # Raw input bytes (String)

key = Restate.key  # Object/workflow key (String)
```

#### Attempt Finished Event

The `attempt_finished_event` on `Restate.request` signals when the current attempt is about to finish
(e.g., the connection is closing). This is useful for long-running handlers that need to perform
cleanup or flush work before the attempt ends.

```ruby
event = Restate.request.attempt_finished_event
event.set?    # Non-blocking check: has the attempt finished? (true/false)
event.wait    # Blocks the current fiber until the attempt finishes
```

### Cancel Invocation

```ruby
Restate.cancel_invocation(invocation_id)
```

---

## Handler Registration

### Class-Based DSL (Recommended)

```ruby
class MyService < Restate::Service
  # Inline decorator style
  handler def greet(name)
    "Hello, #{name}!"
  end

  # With options
  handler :process, input: String, output: Hash
  def process(input)
    { 'result' => input.upcase }
  end
end
```

### Handler Options

```ruby
handler :my_handler,
  input: String,                       # Type or serde for input (generates JSON schema)
  output: Hash,                        # Type or serde for output (generates JSON schema)
  accept: 'application/json',         # Input content type
  content_type: 'application/json'    # Output content type
```

The `input:` and `output:` options accept:
1. A **type class** (e.g., `String`, `Integer`, `Dry::Struct` subclass) — auto-resolves serde + JSON schema
2. A **serde object** (responds to `serialize`/`deserialize`) — used directly
3. Omitted — defaults to `JsonSerde` with no schema

Handlers also accept configuration options that control Restate server behavior:

```ruby
handler :process,
  input: String, output: String,
  description: 'Process a task',              # Human-readable description
  metadata: { 'team' => 'backend' },          # Arbitrary key-value metadata
  inactivity_timeout: 300,                    # Seconds before Restate considers handler inactive
  abort_timeout: 60,                          # Seconds before Restate aborts a stuck handler
  journal_retention: 86_400,                  # Seconds to retain the journal (1 day)
  idempotency_retention: 3600,                # Seconds to retain idempotency keys (1 hour)
  ingress_private: true,                      # Hide from public ingress
  enable_lazy_state: true,                    # Fetch state on demand (VirtualObject/Workflow)
  invocation_retry_policy: {                  # Custom retry policy
    initial_interval: 0.1,                    #   First retry after 100ms
    max_interval: 30,                         #   Cap retry interval at 30s
    max_attempts: 10,                         #   Max 10 attempts
    exponentiation_factor: 2.0,               #   Double interval each retry
    on_max_attempts: :kill                     #   Kill invocation on exhaustion (:pause or :kill)
  }
```

For workflow `main` handlers, there is an additional option:

```ruby
main :run,
  workflow_completion_retention: 86_400       # Seconds to retain workflow completion (1 day)
```

### Custom Service Name

By default, the service name is the unqualified class name. Override it:

```ruby
class MyLongClassName < Restate::Service
  service_name 'ShortName'
  # Registered as "ShortName" in Restate
end
```

### Handler Arity

Handlers receive an optional input parameter with the deserialized request body:

```ruby
handler def no_input                   # Called with null/empty body
  'ok'
end

handler def with_input(data)           # data = deserialized JSON body
  data['name']
end
```

---

## Service Configuration

Use class-level DSL methods to set defaults for the entire service. These are reported to the
Restate server via the discovery protocol and control server-side behavior.

```ruby
class OrderProcessor < Restate::VirtualObject
  # Documentation
  description 'Processes customer orders'
  metadata 'team' => 'commerce', 'tier' => 'critical'

  # Timeouts
  inactivity_timeout 300          # Seconds before Restate considers a handler inactive
  abort_timeout 60                # Seconds before Restate aborts a stuck handler

  # Retention
  journal_retention 86_400        # Seconds to retain the journal (1 day)
  idempotency_retention 3600      # Seconds to retain idempotency keys (1 hour)

  # Access control
  ingress_private                 # Hide from public ingress

  # State loading
  enable_lazy_state               # Fetch state on demand instead of pre-loading

  # Retry policy for handler invocations
  invocation_retry_policy initial_interval: 0.1,
                          max_interval: 30,
                          max_attempts: 10,
                          exponentiation_factor: 2.0,
                          on_max_attempts: :kill

  handler def process(order)
    # ...
  end
end
```

All time values are in **seconds**. All options are optional — when omitted, the Restate server
uses its built-in defaults.

Handler-level options override service-level defaults for individual handlers.

| Option | Service | Handler | Description |
|--------|:---:|:---:|-------------|
| `description` | yes | yes | Human-readable documentation |
| `metadata` | yes | yes | Arbitrary key-value pairs |
| `inactivity_timeout` | yes | yes | Seconds before handler is considered inactive |
| `abort_timeout` | yes | yes | Seconds before a stuck handler is aborted |
| `journal_retention` | yes | yes | Seconds to retain the invocation journal |
| `idempotency_retention` | yes | yes | Seconds to retain idempotency keys |
| `ingress_private` | yes | yes | Hide from public ingress |
| `enable_lazy_state` | yes | yes | Fetch state on demand (VirtualObject/Workflow) |
| `invocation_retry_policy` | yes | yes | Custom retry policy for handler invocations |
| `workflow_completion_retention` | — | main only | Seconds to retain workflow completion |

---

## Endpoint Configuration

The endpoint binds services and creates the Rack application.

```ruby
# Bind multiple services
endpoint = Restate.endpoint(Greeter, Counter, UserSignup)

# Or bind incrementally
endpoint = Restate.endpoint
endpoint.bind(Greeter)
endpoint.bind(Counter, UserSignup)

# Force protocol mode (auto-detected by default)
endpoint.streaming_protocol           # Force bidirectional streaming
endpoint.request_response_protocol    # Force request/response

# Add identity verification keys
endpoint.identity_key('publickeyv1_...')

# Get the Rack app
run endpoint.app  # In config.ru
```

---

## Middleware

Middleware wraps every handler invocation, following the
[Sidekiq middleware](https://github.com/sidekiq/sidekiq/wiki/Middleware) pattern. A middleware is a
class with a `call(handler, ctx)` method that uses `yield` to invoke the next middleware or the
handler itself.

```ruby
class TimingMiddleware
  def call(handler, ctx)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    puts "#{handler.service_tag.name}/#{handler.name} took #{duration}s"
    result
  end
end

endpoint = Restate.endpoint(MyService)
endpoint.use(TimingMiddleware)
```

**Middleware with configuration:**

```ruby
class AuthMiddleware
  def initialize(api_key:)
    @api_key = api_key
  end

  def call(handler, ctx)
    raise Restate::TerminalError.new('unauthorized', status_code: 401) unless valid?(ctx)
    yield
  end
end

endpoint.use(AuthMiddleware, api_key: 'secret')
```

**Available in `call`:**
- `handler.name` — handler method name
- `handler.service_tag.name` — service name
- `handler.service_tag.kind` — `"service"`, `"object"`, or `"workflow"`
- `Restate.request.id` — invocation ID
- `Restate.request.headers` — request headers

Middleware executes in registration order. Each wraps the next, forming an onion around the handler.

See [`middleware_example/`](../middleware_example/) for a complete working example with real
OpenTelemetry tracing and tenant isolation.

---

## Typed Handlers

The `input:` and `output:` options on handler declarations let you use typed structs for
handler I/O. The SDK automatically deserializes input JSON into struct instances and generates
JSON Schema for Restate's discovery protocol.

### Using Dry::Struct

[dry-struct](https://dry-rb.org/gems/dry-struct/) is a popular typed struct library that
Add it as an optional dependency:

```ruby
gem 'dry-struct'
```

```ruby
require 'restate'
require 'dry-struct'

module Types
  include Dry.Types()
end

class GreetingRequest < Dry::Struct
  attribute :name, Types::String
  attribute? :greeting, Types::String    # optional attribute
end

class Greeter < Restate::Service
  handler :greet, input: GreetingRequest, output: String
  def greet(request)
    # request is a GreetingRequest instance, not a raw Hash
    greeting = request.greeting || "Hello"
    "#{greeting}, #{request.name}!"
  end
end
```

Supported dry-types mappings:
| dry-types | JSON Schema |
|-----------|-------------|
| `Types::String` | `{type: 'string'}` |
| `Types::Integer` | `{type: 'integer'}` |
| `Types::Float` | `{type: 'number'}` |
| `Types::Bool` | `{type: 'boolean'}` |
| `Types::Integer.optional` | `{anyOf: [{type: 'integer'}, {type: 'null'}]}` |
| `Types::Array.of(Types::String)` | `{type: 'array', items: {type: 'string'}}` |
| Nested `Dry::Struct` | Recursive object schema |

### How It Works

`Dry::Struct` types are auto-detected at runtime — no configuration needed. When a handler
declares `input: MyRequest`:
- Input JSON is deserialized into a struct instance (not a raw Hash)
- JSON Schema is generated from the struct definition and published via Restate discovery
- Output is serialized based on the `output:` type

### Primitive Types

You can also use primitive Ruby types for simple handlers:

```ruby
handler :greet, input: String, output: String
handler :compute, input: Integer, output: Integer
```

These generate the corresponding JSON Schema (`{type: 'string'}`, `{type: 'integer'}`, etc.)
and use standard JSON serialization.

### Serde Resolution Order

When `input:` or `output:` is provided, the SDK resolves a serde in this order:
1. **Serde object** — if it responds to `serialize` and `deserialize`, use it directly
2. **Dry::Struct subclass** — use `DryStructSerde`
3. **Primitive type** (`String`, `Integer`, etc.) — use `JsonSerde` with type schema
4. **Class with `.json_schema`** — use `JsonSerde` with that schema
5. **Fallback** — `JsonSerde` with no schema

---

## Serialization

### Built-in Serdes

| Serde | Serialize | Deserialize | Use Case |
|-------|-----------|-------------|----------|
| `JsonSerde` (default) | `JSON.generate` | `JSON.parse` | Structured data |
| `BytesSerde` | Pass-through | Pass-through | Raw bytes |

### Custom Serde

Implement a module with `serialize` and `deserialize`:

```ruby
module MarshalSerde
  def self.serialize(obj)
    Marshal.dump(obj).b
  end

  def self.deserialize(buf)
    Marshal.load(buf)  # rubocop:disable Security/MarshalLoad
  end
end

# Use in handler registration
handler :process, input: MarshalSerde, output: MarshalSerde
```

---

## Error Handling

### TerminalError

Raise `TerminalError` to fail a handler permanently (no retries).

```ruby
raise Restate::TerminalError.new('not found', status_code: 404)
```

Terminal errors propagate through service calls:

```ruby
begin
  Restate.service_call(OtherService, :handler, arg).await
rescue Restate::TerminalError => e
  e.message       # Error message
  e.status_code   # HTTP status code
end
```

### Transient Errors

Any `StandardError` (other than `TerminalError`) triggers a retry of the entire invocation.
Restate automatically retries with exponential backoff.

### Important: Avoid Bare Rescue

**Do not** use bare `rescue => e` in handlers — it catches internal SDK control flow exceptions
(`SuspendedError`, `InternalError`) and breaks the durability protocol.

```ruby
# BAD — catches SuspendedError
begin
  result = Restate.service_call(Other, :handler, arg).await
rescue => e
  handle_error(e)
end

# GOOD — catch only what you mean
begin
  result = Restate.service_call(Other, :handler, arg).await
rescue Restate::TerminalError => e
  handle_error(e)
end
```

---

## IDE Code Completion

### Ruby LSP (Recommended)

The SDK works out of the box with [Ruby LSP](https://github.com/Shopify/ruby-lsp) in VSCode.
Install the **Ruby LSP** extension and you'll get code completion, hover docs, and
go-to-definition for all Restate types — no extra setup needed.

Since all Restate operations are called as `Restate.*` module methods, code completion works
automatically without any YARD annotations.

---

## HTTP Client

The SDK ships an HTTP client for invoking Restate services from **outside** the Restate runtime
(e.g., from a web controller, a script, or tests). It uses the Restate ingress HTTP API.

```ruby
require 'restate'

client = Restate::Client.new("http://localhost:8080")

# Stateless service
result = client.service(Greeter).greet("World")
result = client.service("Greeter").greet("World")   # string name also works

# Keyed virtual object
result = client.object(Counter, "my-key").add(5)
result = client.object(Counter, "my-key").get(nil)

# Workflow
result = client.workflow(UserSignup, "user42").run("user@example.com")
```

**With custom headers** (e.g., authentication):

```ruby
client = Restate::Client.new("http://localhost:8080", headers: {
  "Authorization" => "Bearer token123"
})
```

**Note:** The client is for external invocation only. Inside a handler, use the fluent call API
or `Restate.service_call` — these are durable and survive crashes.

---

## Running

### Development

```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080 -n 1
```

### Production

```bash
bundle exec falcon serve --bind http://0.0.0.0:9080
```

### Docker

```dockerfile
FROM ruby:3.3-slim-bookworm
RUN apt-get update && apt-get install -y build-essential curl clang \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install && bundle exec rake compile
COPY . .
CMD ["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:9080"]
```

### Register with Restate

```bash
# Using Restate CLI
restate deployments register http://localhost:9080

# Using admin API directly
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080"}'

# Force re-register after code changes
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080", "force": true}'
```

---

## Testing

The SDK ships a test harness that starts a real Restate server via Docker, serves your services
on a local Falcon server, and registers them automatically. No external setup is needed — just
Docker.

Opt-in with `require 'restate/testing'`. Add `testcontainers-core` to your Gemfile:

```ruby
gem 'testcontainers-core', require: false
```

### Block-Based (Recommended)

```ruby
require 'restate/testing'

Restate::Testing.start(Greeter, Counter) do |env|
  # env.ingress_url  => "http://localhost:32771"
  # env.admin_url    => "http://localhost:32772"

  uri = URI("#{env.ingress_url}/Greeter/greet")
  request = Net::HTTP::Post.new(uri)
  request['Content-Type'] = 'application/json'
  request.body = '"World"'
  response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
  puts response.body  # => "Hello, World!"
end
# Container and server are automatically cleaned up.
```

### Manual Lifecycle (for RSpec hooks)

```ruby
require 'restate/testing'

RSpec.describe 'my services' do
  before(:all) do
    @harness = Restate::Testing::RestateTestHarness.new(Greeter, Counter)
    @harness.start
  end

  after(:all) do
    @harness&.stop
  end

  it 'greets' do
    uri = URI("#{@harness.ingress_url}/Greeter/greet")
    request = Net::HTTP::Post.new(uri)
    request['Content-Type'] = 'application/json'
    request.body = '"World"'
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    expect(JSON.parse(response.body)).to eq('Hello, World!')
  end
end
```

### Configuration Options

All options are keyword arguments on both `start` and `RestateTestHarness.new`:

| Option | Default | Description |
|--------|---------|-------------|
| `restate_image:` | `"docker.io/restatedev/restate:latest"` | Docker image for Restate server |
| `always_replay:` | `false` | Force replay on every suspension point (useful for catching non-determinism bugs) |
| `disable_retries:` | `false` | Disable Restate retry policy |

```ruby
Restate::Testing.start(MyService, always_replay: true, disable_retries: true) do |env|
  # ...
end
```

### Running Harness Tests

```bash
make test-harness  # Requires Docker
```

---

## URL Patterns

| Service Type | URL Pattern | Example |
|-------------|-------------|---------|
| Service | `/ServiceName/handler` | `/Greeter/greet` |
| VirtualObject | `/ObjectName/key/handler` | `/Counter/my-counter/add` |
| Workflow | `/WorkflowName/key/handler` | `/UserSignup/user42/run` |

---

## Examples

The `examples/` directory contains runnable examples:

| File | Shows |
|------|-------|
| `greeter.rb` | Hello World: simplest stateless service |
| `durable_execution.rb` | `Restate.run`, `Restate.run_sync`, `background: true`, `RunRetryPolicy`, `TerminalError` |
| `virtual_objects.rb` | Declarative state, `handler` vs `shared`, `state_keys`, `clear_all` |
| `workflow.rb` | Declarative state, promises, signals |
| `service_communication.rb` | Fluent call API, fan-out/fan-in, `wait_any`, awakeables |
| `typed_handlers.rb` | `input:`/`output:` with `Dry::Struct`, JSON Schema generation |
| `service_configuration.rb` | Service-level config: timeouts, retention, retry policy, lazy state |
| [`middleware_example/`](../middleware_example/) | Real OpenTelemetry tracing + tenant isolation middleware (self-contained) |

Run any example:
```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080
restate deployments register http://localhost:9080
```

---

## Complete API Quick Reference

### Service Types

```ruby
class MyService < Restate::Service
  handler def method(arg)
    # Use Restate.* methods for all operations
  end
end

class MyObject < Restate::VirtualObject
  state :count, default: 0                       # Declarative state
  handler def exclusive_method(arg)              # One at a time per key
  end
  shared def concurrent_method                   # Many readers
  end
end

class MyWorkflow < Restate::Workflow
  state :status, default: 'pending'              # Declarative state
  main def run(arg)                              # Runs once per key
  end
  handler def query                              # Shared handler
  end
end
```

### Context Methods

```ruby
# Declarative state (VirtualObject / Workflow)
state :name, default: nil, serde: nil  # class-level macro
self.name / self.name= / clear_name   # generated instance methods

# Explicit state (VirtualObject / Workflow)
Restate.get(name) -> value | nil
Restate.get_async(name) -> DurableFuture
Restate.set(name, value)
Restate.clear(name)
Restate.clear_all
Restate.state_keys -> Array[String]
Restate.state_keys_async -> DurableFuture

# Durable execution
Restate.run(name, background: false) { block } -> DurableFuture
Restate.run_sync(name, background: false) { block } -> value   # run + await
Restate.sleep(seconds) -> DurableFuture

# Fluent service calls (recommended)
MyService.call.handler(arg) -> DurableCallFuture
MyObject.call("key").handler(arg) -> DurableCallFuture
MyWorkflow.call("key").handler(arg) -> DurableCallFuture

# Fluent fire-and-forget
MyService.send!.handler(arg) -> SendHandle
MyObject.send!("key").handler(arg) -> SendHandle
MyService.send!(delay: 60).handler(arg) -> SendHandle

# Explicit service calls
Restate.service_call(svc, handler, arg) -> DurableCallFuture
Restate.object_call(svc, handler, key, arg) -> DurableCallFuture
Restate.workflow_call(svc, handler, key, arg) -> DurableCallFuture

# Explicit fire-and-forget
Restate.service_send(svc, handler, arg, delay: nil) -> SendHandle
Restate.object_send(svc, handler, key, arg, delay: nil) -> SendHandle
Restate.workflow_send(svc, handler, key, arg, delay: nil) -> SendHandle

# Awakeables
Restate.awakeable -> [id, DurableFuture]
Restate.resolve_awakeable(id, payload)
Restate.reject_awakeable(id, message, code: 500)

# Promises (Workflow only)
Restate.promise(name) -> value           # Blocks until resolved
Restate.peek_promise(name) -> value | nil
Restate.resolve_promise(name, payload)
Restate.reject_promise(name, message, code: 500)

# Futures
Restate.wait_any(*futures) -> [completed, remaining]

# Metadata
Restate.request -> Request{id, headers, body}
Restate.request.attempt_finished_event -> AttemptFinishedEvent
Restate.key -> String

# Cancellation
Restate.cancel_invocation(invocation_id)
```

### Future Methods

```ruby
# DurableFuture (from Restate.run, Restate.sleep)
future.await -> value
future.completed? -> bool

# DurableCallFuture (from Restate.service_call, etc.)
future.await -> value
future.completed? -> bool
future.invocation_id -> String
future.cancel

# SendHandle (from Restate.service_send, etc.)
handle.invocation_id -> String
handle.cancel
```

### Middleware

```ruby
endpoint.use(MyMiddleware)            # Register middleware
endpoint.use(MyMiddleware, arg: val)  # With constructor args
```

### HTTP Client (External Invocation)

```ruby
client = Restate::Client.new("http://localhost:8080")
client.service(Greeter).greet("World")
client.object(Counter, "key").add(5)
client.workflow(UserSignup, "key").run(email)
```
