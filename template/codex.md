# Restate Ruby SDK Project

This is a Restate service written in Ruby using the [Restate Ruby SDK](https://github.com/restatedev/sdk-ruby).

## What is Restate?

Restate is a system for building resilient applications using distributed durable async/await.
Handlers survive crashes, retries, and infrastructure failures — with the simplicity of ordinary Ruby code.

## Project structure

- `config.ru` — Rack entry point, binds services to a Restate endpoint
- `greeter.rb` — Example service (add your own service files alongside it)
- `Gemfile` — Dependencies

## Running

```bash
bundle exec falcon serve --bind http://localhost:9080   # Start the service
restate deployments register http://localhost:9080       # Register with Restate
```

## Key concepts

### Service types

- `Restate::Service` — Stateless handlers, invoked by name
- `Restate::VirtualObject` — Keyed, stateful handlers (one invocation at a time per key)
- `Restate::Workflow` — Durable run-once workflows with promises for signaling

### Restate API

All Restate operations are available as top-level `Restate.*` module methods. Call them
directly inside any handler:

```ruby
handler def greet(name)
  Restate.run_sync('step') { ... }
end
```

### Durable execution

```ruby
# Side effect — runs exactly once, result is journaled
result = Restate.run_sync('step-name') { do_something() }

# Async variant — returns a future
future = Restate.run('step-name') { do_something() }
result = future.await
```

### State (VirtualObject / Workflow only)

```ruby
Restate.get('key')                # Read (nil if absent)
Restate.set('key', value)         # Write
Restate.clear('key')              # Delete
Restate.clear_all                 # Delete all
Restate.state_keys                # List keys
```

### Service communication

```ruby
# Fluent call API (recommended)
result = Worker.call.process(task).await
result = Counter.call("key").add(5).await

# Fluent fire-and-forget
Worker.send!.process(task)
Worker.send!(delay: 60).process(task)

# Explicit calls
result = Restate.service_call(MyService, :handler, arg).await
result = Restate.object_call(MyObject, :handler, 'key', arg).await

# Explicit fire-and-forget
Restate.service_send(MyService, :handler, arg)
Restate.object_send(MyObject, :handler, 'key', arg, delay: 60.0)
```

### Typed handlers with T::Struct

Use Sorbet's `T::Struct` for typed input/output with automatic JSON Schema generation:

```ruby
class MyRequest < T::Struct
  const :name, String
  const :age, T.nilable(Integer)
end

class MyService < Restate::Service
  handler :process, input: MyRequest, output: String
  def process(request)
    "Hello, #{request.name}!"
  end
end
```

Supported types: `String`, `Integer`, `Float`, `T::Boolean`, `T.nilable(...)`, `T::Array[...]`, `T::Hash[...]`, nested `T::Struct`.

### Sleep (durable timer)

```ruby
Restate.sleep(5.0).await          # Survives crashes
```

### Awakeables (external callbacks)

```ruby
awakeable_id, future = Restate.awakeable
Restate.run_sync('notify') { send_to_external(awakeable_id) }
result = future.await
```

### Promises (Workflow only)

```ruby
value = Restate.promise('approval')                    # Block until resolved
Restate.resolve_promise('approval', value)             # From signal handler
```

### Error handling

```ruby
# Terminal error — no retries
raise Restate::TerminalError.new('not found', status_code: 404)

# Any other StandardError triggers a retry
# IMPORTANT: never use bare `rescue => e` — it catches internal SDK exceptions
```

### Endpoint configuration

```ruby
endpoint = Restate.endpoint(ServiceA, ServiceB)
run endpoint.app   # in config.ru
```

## Code style

- Use `T::Struct` for typed handler input/output
- Use `Restate.*` module methods for all operations (run, sleep, get, set, service_call, etc.)
- Use `run_sync` for sequential side effects, `run` + `.await` for fan-out
- Catch `Restate::TerminalError` specifically, never bare `rescue => e`
