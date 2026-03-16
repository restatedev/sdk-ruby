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
    ctx = Restate.current_context
    ctx.run_sync('build-greeting') { "Hello, #{name}!" }
  end
end

ENDPOINT = Restate.endpoint(Greeter)
```

### 2. Create a Rackup File

```ruby
# config.ru
require_relative 'greeter'
run ENDPOINT.app
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
  # Exclusive handler — one invocation at a time per key.
  handler def add(amount)
    ctx = Restate.current_object_context
    current = ctx.get('count') || 0
    ctx.set('count', current + amount)
    current + amount
  end

  # Shared handler — concurrent access allowed (read-only).
  shared def get
    ctx = Restate.current_object_context
    ctx.get('count') || 0
  end
end
```

**Invoke**: `POST /Counter/my-counter/add` (key is `my-counter`)

### Workflow (Durable, Run-Once)

A workflow's `main` handler runs exactly once per key. Shared handlers let external callers
query state and send signals.

```ruby
class UserSignup < Restate::Workflow
  main def run(email)
    ctx = Restate.current_workflow_context
    user_id = ctx.run_sync('create-account') { create_user(email) }
    ctx.set('status', 'waiting_for_approval')

    # Block until approve() is called
    approval = ctx.promise('approval')
    ctx.set('status', 'active')
    { 'user_id' => user_id, 'approval' => approval }
  end

  handler def approve(reason)
    ctx = Restate.current_workflow_context
    ctx.resolve_promise('approval', reason)
  end

  handler def status
    ctx = Restate.current_workflow_context
    ctx.get('status') || 'unknown'
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

The context object provides access to all Restate operations. Obtain it at the start of your
handler using the appropriate fiber-local accessor:

```ruby
ctx = Restate.current_context                  # Service handlers
ctx = Restate.current_object_context           # VirtualObject handlers
ctx = Restate.current_workflow_context         # Workflow handlers
```

All operations that interact with Restate return durable results — if the handler crashes and
retries, completed operations are replayed from the journal without re-executing.

### Durable Execution (`ctx.run`)

Execute a side effect exactly once. The result is durably recorded — on retry, the block is
skipped and the stored result is returned.

`run` returns a `DurableFuture`; call `.await` to get the result. Use `run_sync` to get
the value directly:

```ruby
# Returns a future — useful for fan-out (see below)
future = ctx.run('step-name') { do_something() }
result = future.await

# Returns the value directly — convenient for sequential steps
result = ctx.run_sync('step-name') { do_something() }
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

result = ctx.run_sync('flaky-call', retry_policy: policy) { call_external_api() }
```

**Terminal errors** (non-retryable):
```ruby
ctx.run_sync('validate') do
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
result = ctx.run_sync('resize-image', background: true) { process_image(data) }
```

### State Operations

Available in `VirtualObject` and `Workflow` handlers.

```ruby
value = ctx.get('key')              # Read state (nil if absent)
ctx.set('key', value)               # Write state
ctx.clear('key')                    # Delete one key
ctx.clear_all                       # Delete all keys
keys = ctx.state_keys               # List all key names
```

**Async variants** — return a `DurableFuture` instead of blocking, useful for fan-out:

```ruby
future_a = ctx.get_async('key_a')
future_b = ctx.get_async('key_b')
keys_future = ctx.state_keys_async

# Await results (fetches happen concurrently)
val_a = future_a.await
val_b = future_b.await
keys = keys_future.await
```

Values are JSON-serialized by default. Pass `serde:` for custom serialization:

```ruby
ctx.get('key', serde: Restate::BytesSerde)
ctx.get_async('key', serde: Restate::BytesSerde)
ctx.set('key', raw_bytes, serde: Restate::BytesSerde)
```

### Sleep

```ruby
ctx.sleep(5.0).await                # Sleep for 5 seconds (durable timer)
```

The timer survives crashes — if the handler restarts, it resumes waiting for the remaining time.

### Service Communication

#### Synchronous Calls

Call another handler and await the result. The call is durable — if the caller crashes,
Restate delivers the result when the caller retries.

```ruby
# Typed call (resolves serdes from target handler registration)
result = ctx.service_call(MyService, :my_handler, arg).await
result = ctx.object_call(Counter, :add, 'my-key', 5).await
result = ctx.workflow_call(UserSignup, :run, 'user42', email).await

# String-based call (uses JsonSerde)
result = ctx.service_call('MyService', 'my_handler', arg).await
```

**DurableCallFuture methods:**
```ruby
future = ctx.service_call(MyService, :handler, arg)
result = future.await                # Block until result
id = future.invocation_id            # Get invocation ID
future.cancel                        # Cancel the remote invocation
```

#### Fire-and-Forget Sends

Dispatch a call without waiting for the result.

```ruby
handle = ctx.service_send(MyService, :handler, arg)
handle = ctx.object_send(Counter, :add, 'my-key', 5)

# Delayed send (executes after 60 seconds)
handle = ctx.service_send(MyService, :handler, arg, delay: 60.0)
```

**SendHandle methods:**
```ruby
id = handle.invocation_id            # Get invocation ID
handle.cancel                        # Cancel the invocation
```

#### Call Options

All call/send methods accept these keyword arguments:

```ruby
ctx.service_call(
  MyService, :handler, arg,
  idempotency_key: 'unique-key',     # Deduplication key
  headers: { 'x-custom' => 'val' },  # Custom headers
  input_serde: MyCustomSerde,        # Override input serializer
  output_serde: MyCustomSerde        # Override output serializer
)
```

### Fan-Out / Fan-In

Launch multiple calls concurrently, then collect all results.

```ruby
# Fan-out: launch calls
futures = tasks.map { |t| ctx.service_call(Worker, :process, t) }

# Fan-in: await all
results = futures.map(&:await)
```

### Wait Any (Racing Futures)

Wait for the first future to complete out of several.

```ruby
future_a = ctx.service_call(ServiceA, :slow, arg)
future_b = ctx.service_call(ServiceB, :fast, arg)

completed, remaining = ctx.wait_any(future_a, future_b)
winner = completed.first.await
```

### Awakeables (External Callbacks)

Pause a handler until an external system calls back via Restate's API.

```ruby
# In your handler: create an awakeable
awakeable_id, future = ctx.awakeable

# Send the ID to an external system
ctx.run_sync('notify') { send_to_external_system(awakeable_id) }

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
ctx.resolve_awakeable(awakeable_id, payload)
ctx.reject_awakeable(awakeable_id, 'reason', code: 500)
```

### Promises (Workflow Only)

Durable promises allow communication between a workflow's main handler and its signal handlers.

```ruby
# In main handler: block until promise is resolved
value = ctx.promise('approval')

# In signal handler: resolve the promise
ctx.resolve_promise('approval', value)

# Non-blocking peek (returns nil if not yet resolved)
value = ctx.peek_promise('approval')

# Reject a promise
ctx.reject_promise('approval', 'denied', code: 400)
```

### Request Metadata

```ruby
request = ctx.request
request.id         # Invocation ID (String)
request.headers    # Request headers (Hash)
request.body       # Raw input bytes (String)

key = ctx.key      # Object/workflow key (String)
```

#### Attempt Finished Event

The `attempt_finished_event` on `ctx.request` signals when the current attempt is about to finish
(e.g., the connection is closing). This is useful for long-running handlers that need to perform
cleanup or flush work before the attempt ends.

```ruby
event = ctx.request.attempt_finished_event
event.set?    # Non-blocking check: has the attempt finished? (true/false)
event.wait    # Blocks the current fiber until the attempt finishes
```

### Accessing the Context

Handlers obtain the Restate context via fiber-local accessors. This is the standard way to
access the context — call the appropriate accessor at the start of your handler (or from any
method within the same fiber):

```ruby
class OrderService < Restate::Service
  handler def process(order)
    ctx = Restate.current_context
    validate(order)
    fulfill(order)
  end

  private

  def validate(order)
    # Works from any method within the handler's fiber
    ctx = Restate.current_context
    ctx.run_sync('validate') { check_inventory(order) }
  end

  def fulfill(order)
    ctx = Restate.current_context
    ctx.run_sync('fulfill') { ship_order(order) }
  end
end
```

The following accessors are available, each returning the appropriately-typed context:

| Accessor | Returns | Use in |
|----------|---------|--------|
| `Restate.current_context` | `Context` | Any handler |
| `Restate.current_object_context` | `ObjectContext` | VirtualObject exclusive handlers (full state) |
| `Restate.current_shared_context` | `ObjectSharedContext` | VirtualObject shared handlers (read-only state) |
| `Restate.current_workflow_context` | `WorkflowContext` | Workflow `main` handler (full state + promises) |
| `Restate.current_shared_workflow_context` | `WorkflowSharedContext` | Workflow shared handlers (read-only state + promises) |

Shared contexts (`ObjectSharedContext`, `WorkflowSharedContext`) expose `get` and `state_keys`
but NOT `set`, `clear`, or `clear_all` — shared handlers have read-only access to state.

**Runtime validation**: Calling the wrong accessor for your handler type (e.g.,
`Restate.current_object_context` from a Service handler) raises an error. Calling any accessor
outside a handler also raises.

**Implementation**: These use fiber-local storage (`Thread.current[:key]`, which is fiber-scoped
in Ruby). The context is set automatically when a handler begins and cleared when it returns.

### Cancel Invocation

```ruby
ctx.cancel_invocation(invocation_id)
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

### Custom Service Name

By default, the service name is the unqualified class name. Override it:

```ruby
class MyLongClassName < Restate::Service
  service_name 'ShortName'
  # Registered as "ShortName" in Restate
end
```

### Handler Arity

Handlers can accept 0 or 1 parameters:

```ruby
handler def no_input              # Called with null/empty body
  'ok'
end

handler def with_input(data)      # data = deserialized JSON body
  data['name']
end
```

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

## Typed Handlers

The `input:` and `output:` options on handler declarations let you use typed structs for
handler I/O. The SDK automatically deserializes input JSON into struct instances and generates
JSON Schema for Restate's discovery protocol.

Two struct libraries are supported out of the box — pick whichever fits your project:

### Using T::Struct (Sorbet)

If you already use [Sorbet](https://sorbet.org/), `T::Struct` gives you full type safety
and IDE support with no extra dependencies.

```ruby
require 'restate'

class GreetingRequest < T::Struct
  const :name, String
  const :greeting, T.nilable(String)
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

The SDK introspects `T::Struct` props to generate JSON Schema. Serialization uses
`T::Struct#serialize` and `.from_hash`.

Supported Sorbet type mappings:
| Sorbet type | JSON Schema |
|-------------|-------------|
| `String` | `{type: 'string'}` |
| `Integer` | `{type: 'integer'}` |
| `Float` | `{type: 'number'}` |
| `T::Boolean` | `{type: 'boolean'}` |
| `T.nilable(String)` | `{anyOf: [{type: 'string'}, {type: 'null'}]}` |
| `T::Array[String]` | `{type: 'array', items: {type: 'string'}}` |
| `T::Hash[String, Integer]` | `{type: 'object'}` |
| Nested `T::Struct` | Recursive object schema |

### Using Dry::Struct

[dry-struct](https://dry-rb.org/gems/dry-struct/) is a popular typed struct library that
works without Sorbet. Add it as an optional dependency:

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

Both struct types are auto-detected at runtime — no configuration needed. When a handler
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
2. **T::Struct subclass** — use `TStructSerde` (Sorbet native)
3. **Dry::Struct subclass** — use `DryStructSerde`
4. **Primitive type** (`String`, `Integer`, etc.) — use `JsonSerde` with type schema
5. **Class with `.json_schema`** — use `JsonSerde` with that schema
6. **Fallback** — `JsonSerde` with no schema

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
  ctx.service_call(OtherService, :handler, arg).await
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
  result = ctx.service_call(Other, :handler, arg).await
rescue => e
  handle_error(e)
end

# GOOD — catch only what you mean
begin
  result = ctx.service_call(Other, :handler, arg).await
rescue Restate::TerminalError => e
  handle_error(e)
end
```

---

## IDE Code Completion (Optional)

The SDK ships a [Tapioca](https://github.com/Shopify/tapioca) DSL compiler that gives your IDE
full code completion for handler methods — with zero annotations in your code.

The compiler generates [Sorbet](https://sorbet.org/) type signatures for handler input parameters
and return types.

### Setup

**1. Add Sorbet and Tapioca to your Gemfile** (skip if you already use them):

```ruby
group :development do
  gem 'sorbet', require: false
  gem 'tapioca', require: false
end
```

**2. Install and initialize** (one-time):

```bash
bundle install
bundle exec tapioca init
```

**3. Generate the handler type signatures:**

```bash
bundle exec tapioca dsl
```

This creates RBI files under `sorbet/rbi/dsl/` — one per service class. For example, given:

```ruby
class Counter < Restate::VirtualObject
  handler def add(addend)
    ctx = Restate.current_object_context
    old = ctx.get('count') || 0
    ctx.set('count', old + addend)
  end

  shared def get
    ctx = Restate.current_object_context
    ctx.get('count') || 0
  end
end
```

Tapioca generates:

```ruby
# sorbet/rbi/dsl/counter.rbi (auto-generated, do not edit)
class Counter
  sig { params(input: T.untyped).returns(T.untyped) }
  def add(input); end

  sig { returns(T.untyped) }
  def get; end
end
```

Your IDE now offers completion for handler parameters and return types.

### Re-generate after changes

Run `tapioca dsl` again whenever you add or rename handlers:

```bash
bundle exec tapioca dsl
```

Commit the generated `sorbet/rbi/dsl/` files to version control so the whole team benefits.

### Without Sorbet

If you don't use Sorbet, you can still get completion in YARD-aware editors (Solargraph, RubyMine)
by adding type annotations to the context accessor:

```ruby
class Greeter < Restate::Service
  handler def greet(name)
    # @type [Restate::Context]
    ctx = Restate.current_context
    ctx.run_sync('step') { "Hello, #{name}!" }
  end
end
```

Use `Restate::Context`, `Restate::ObjectContext`, or `Restate::WorkflowContext` depending on
the service type.

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
| `durable_execution.rb` | `ctx.run`, `ctx.run_sync`, `background: true`, `RunRetryPolicy`, `TerminalError` |
| `virtual_objects.rb` | State ops, `handler` vs `shared`, `state_keys`, `clear_all` |
| `workflow.rb` | Promises, signals, workflow state |
| `service_communication.rb` | Calls, sends, fan-out/fan-in, `wait_any`, awakeables |
| `typed_handlers.rb` | `input:`/`output:` with `Dry::Struct`, JSON Schema generation |
| `typed_handlers_sorbet.rb` | `input:`/`output:` with `T::Struct` (Sorbet), JSON Schema generation |

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
    ctx = Restate.current_context
  end
end

class MyObject < Restate::VirtualObject
  handler def exclusive_method(arg)              # One at a time per key
    ctx = Restate.current_object_context
  end
  shared def concurrent_method                   # Many readers
    ctx = Restate.current_object_context
  end
end

class MyWorkflow < Restate::Workflow
  main def run(arg)                              # Runs once per key
    ctx = Restate.current_workflow_context
  end
  handler def query                              # Shared handler
    ctx = Restate.current_workflow_context
  end
end
```

### Context Methods

```ruby
# State (VirtualObject / Workflow)
ctx.get(name) → value | nil
ctx.get_async(name) → DurableFuture
ctx.set(name, value)
ctx.clear(name)
ctx.clear_all
ctx.state_keys → Array[String]
ctx.state_keys_async → DurableFuture

# Durable execution
ctx.run(name, background: false) { block } → DurableFuture
ctx.run_sync(name, background: false) { block } → value   # run + await
ctx.sleep(seconds) → DurableFuture

# Service calls
ctx.service_call(svc, handler, arg) → DurableCallFuture
ctx.object_call(svc, handler, key, arg) → DurableCallFuture
ctx.workflow_call(svc, handler, key, arg) → DurableCallFuture

# Fire-and-forget
ctx.service_send(svc, handler, arg, delay: nil) → SendHandle
ctx.object_send(svc, handler, key, arg, delay: nil) → SendHandle
ctx.workflow_send(svc, handler, key, arg, delay: nil) → SendHandle

# Awakeables
ctx.awakeable → [id, DurableFuture]
ctx.resolve_awakeable(id, payload)
ctx.reject_awakeable(id, message, code: 500)

# Promises (Workflow only)
ctx.promise(name) → value           # Blocks until resolved
ctx.peek_promise(name) → value | nil
ctx.resolve_promise(name, payload)
ctx.reject_promise(name, message, code: 500)

# Futures
ctx.wait_any(*futures) → [completed, remaining]

# Metadata
ctx.request → Request{id, headers, body}
ctx.request.attempt_finished_event → AttemptFinishedEvent
ctx.key → String

# Cancellation
ctx.cancel_invocation(invocation_id)
```

### Fiber-Local Context Accessors

```ruby
Restate.current_context                  # → Context (any handler)
Restate.current_object_context           # → ObjectContext (exclusive — full state)
Restate.current_shared_context           # → ObjectSharedContext (shared — read-only state)
Restate.current_workflow_context         # → WorkflowContext (main — full state + promises)
Restate.current_shared_workflow_context  # → WorkflowSharedContext (shared — read-only + promises)
```

### Future Methods

```ruby
# DurableFuture (from ctx.run, ctx.sleep)
future.await → value
future.completed? → bool

# DurableCallFuture (from ctx.service_call, etc.)
future.await → value
future.completed? → bool
future.invocation_id → String
future.cancel

# SendHandle (from ctx.service_send, etc.)
handle.invocation_id → String
handle.cancel
```
