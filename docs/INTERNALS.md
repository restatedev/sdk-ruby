# Restate Ruby SDK — Internals

This document describes the internal architecture, execution flow, and important implementation
details of the Restate Ruby SDK. It is intended for contributors and AI assistants working on
the codebase.

## Architecture Overview

```
  Restate Runtime
      │ HTTP/2 (BidiStream protocol)
      ▼
  Falcon (HTTP/2 server, fiber-based via Async)
      │ Rack 3 interface
      ▼
  Restate::Server                    ← lib/restate/server.rb
      │ routes requests, manages streaming I/O
      ▼
  Restate::ServerContext             ← lib/restate/server_context.rb
      │ progress loop, context API for handlers
      ▼
  Restate::VMWrapper                 ← lib/restate/vm.rb
      │ maps native types to Ruby types
      ▼
  Restate::Internal::VM              ← ext/restate_internal/src/lib.rs
      │ Magnus (Ruby ↔ Rust FFI)
      ▼
  restate-sdk-shared-core            (Rust crate, protocol state machine)
```

The SDK is a Rack 3 application designed for Falcon. It wraps the shared Rust
`restate-sdk-shared-core` VM — the same core used by the Python, TypeScript, and other SDKs.

## Components

### Native Extension (`ext/restate_internal/src/lib.rs`)

A Rust crate compiled via `rb_sys` + `magnus` into a Ruby native extension loaded as
`require "restate_internal"`. It exposes:

- **`Restate::Internal::VM`** — wraps `CoreVM`. All protocol logic lives in the Rust core;
  Ruby just drives it.
- **Data types** — `Header`, `ResponseHead`, `Failure`, `Input`, `CallHandle`,
  `ExponentialRetryConfig`, progress response types (`DoProgressAnyCompleted`,
  `DoProgressReadFromInput`, `DoProgressExecuteRun`, `DoProgressCancelSignalReceived`,
  `DoWaitForPendingRun`, `Suspended`), `Void`, `StateKeys`.
- **`IdentityVerifier`** — verifies request identity signatures.
- **Error formatter** — provides Ruby-specific error messages (e.g., warning about bare
  `rescue` catching `SuspendedError`).

The init function **must** be annotated `#[magnus::init(name = "restate_internal")]` to match
the `require` path. Without the explicit name, Magnus derives the symbol from the crate name
which may include hyphens.

### VMWrapper (`lib/restate/vm.rb`)

Thin Ruby wrapper that:
1. Creates a `Internal::VM` with request headers.
2. Delegates all `sys_*` calls.
3. Maps native result types to Ruby-side types (e.g., `Internal::Suspended` → `Restate::Suspended`,
   `Internal::Failure` → `Restate::Failure`).
4. Catches `Internal::VMError` from `do_progress`/`take_notification` and returns it as a value
   (not raised), so `ServerContext` can handle it.

### Server (`lib/restate/server.rb`)

Rack 3 application with three routes:

| Method | Path                         | Handler              |
|--------|------------------------------|----------------------|
| GET    | `/health`                    | `health_response`    |
| GET    | `/discover`                  | `handle_discover`    |
| POST   | `/invoke/:service/:handler`  | `handle_invocation`  |

#### Discovery

Negotiates protocol version from the `Accept` header (v2, v3, v4). Auto-detects protocol mode
from HTTP version (HTTP/2 → `BIDI_STREAM`, HTTP/1.1 → `REQUEST_RESPONSE`), or uses the endpoint's
forced protocol setting.

#### Invocation Flow

This is the most complex part. See [Invocation Execution Flow](#invocation-execution-flow) below.

### ServerContext (`lib/restate/server_context.rb`)

Implements:
- **Progress loop** (`poll_or_cancel`) — the core execution driver.
- **Context API** — `get`, `set`, `clear`, `clear_all`, `state_keys`, `sleep`, `run`,
  `service_call`, `service_send`, `object_call`, `object_send`, `workflow_call`, `workflow_send`.
- **Run execution** — spawns durable side effects as Async child tasks.

### Service Types

- **`Service`** (`lib/restate/service.rb`) — stateless, handlers have no `kind`.
- **`VirtualObject`** (`lib/restate/virtual_object.rb`) — keyed + stateful, handlers default to
  `:exclusive`.
- **`Workflow`** (`lib/restate/workflow.rb`) — keyed + stateful, has `.main()` (kind=workflow,
  runs once per key) and `.handler()` (kind=shared).

### Handler Dispatch (`lib/restate/handler.rb`)

`Restate.invoke_handler` deserializes input via `handler_io.input_serde`, calls the block with
`(ctx)` or `(ctx, input)` based on arity, then serializes output via `handler_io.output_serde`.

### Serialization (`lib/restate/serde.rb`)

- **`JsonSerde`** — default. `JSON.generate` / `JSON.parse`. Returns binary-encoded strings (`.b`).
- **`BytesSerde`** — pass-through for raw bytes.

## Invocation Execution Flow

When Restate invokes a handler, the following happens:

### Phase 1: Input Ingestion

```
HTTP/2 request body (streaming)
    │
    ▼
rack.input.read_partial(16384)  ──► vm.notify_input(chunk)
    │                                    │
    │                            vm.is_ready_to_execute?
    │                                    │
    ├── not ready yet ◄─── false ────────┘
    │       └── loop back to read_partial
    │
    └── ready ◄──────── true ────────────┘
            └── break out of loop
```

**CRITICAL**: Must use `read_partial`, NOT `read`. See [Important Learnings](#important-learnings).

### Phase 2: Setup

After the VM is ready:
1. `vm.sys_input` returns the `Invocation` (id, headers, input buffer, key).
2. A background **input reader** Async task continues reading remaining HTTP body into
   `input_queue`.
3. A `ServerContext` is created with the VM, handler, invocation, output callback, and input queue.

### Phase 3: Handler Execution (Async task)

```
Async task:
    context.enter()
        │
        ▼
    invoke_handler(handler, ctx, input_buffer)
        │
        ▼ (handler calls ctx.get, ctx.run, ctx.service_call, etc.)
        │
    Each ctx method calls vm.sys_* then poll_and_take(handle)
        │
        ▼
    poll_or_cancel (progress loop)
```

### Phase 4: Progress Loop

```
loop:
    flush_output()  ──► drain vm.take_output → output_queue
        │
        ▼
    vm.do_progress(handles)
        │
        ├── AnyCompleted        → return (handle is done)
        ├── ReadFromInput       → dequeue from input_queue
        │       ├── String      → vm.notify_input(chunk)
        │       ├── :eof        → vm.notify_input_closed
        │       ├── :disconnected → raise DisconnectedError
        │       └── :run_completed → next iteration
        ├── DoWaitPendingRun    → same as ReadFromInput
        ├── ExecuteRun(handle)  → spawn Async task for run block
        ├── CancelSignalReceived → raise TerminalError(409)
        └── Suspended           → raise SuspendedError
```

### Phase 5: Output Streaming

Output flows through two paths:

1. **During handler execution**: `flush_output()` in the progress loop drains the VM and enqueues
   chunks to `output_queue`.
2. **After handler completes**: The handler Async task drains any remaining VM output, then
   enqueues `nil` to signal end-of-stream.

The `StreamingBody` (Rack 3 body) sits on the other end of `output_queue`, yielding chunks to
Falcon as they arrive:

```
vm.take_output → output_queue.enqueue(chunk) ··· output_queue.dequeue → yield to Falcon → HTTP/2
```

### Concurrency Diagram

```
┌─────────────────────────────────────────────────────────┐
│  Falcon Fiber (HTTP request)                            │
│                                                         │
│  1. Read initial input → VM ready                       │
│  2. Spawn background input reader (Async task A)        │
│  3. Spawn handler execution (Async task B)              │
│  4. Return [status, headers, StreamingBody]             │
│     └── StreamingBody.each blocks on output_queue       │
└─────────────────────────────────────────────────────────┘

┌──────────────────────────┐  ┌──────────────────────────┐
│  Async Task A:           │  │  Async Task B:           │
│  Input Reader            │  │  Handler + Progress Loop │
│                          │  │                          │
│  loop:                   │  │  context.enter()         │
│    chunk = read_partial  │  │    invoke_handler(...)   │
│    input_queue << chunk  │  │    poll_or_cancel:       │
│  ensure:                 │  │      flush_output → out_q│
│    input_queue << :eof   │  │      do_progress         │
│                          │  │      input_q.dequeue     │
│                          │  │  drain remaining output  │
│                          │  │  output_queue << nil     │
└──────────────────────────┘  └──────────────────────────┘
```

## Manual Testing

### Prerequisites

1. **Restate runtime** must be running (default ingress on `:8080`, admin API on `:9070`).
2. **Native extension** must be compiled: `make compile` (or `bundle exec rake compile`).

### Start the Example Server

```bash
cd examples
bundle exec falcon serve --bind http://localhost:9080
```

Use `-n 1` for a single worker (easier debugging).

### Register the Deployment

The `restate` CLI may not be on PATH in all environments. Use the admin API directly:

```bash
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080"}'
```

To force re-registration after code changes (restarts the Falcon server first):

```bash
curl http://localhost:9070/deployments \
  -H 'content-type: application/json' \
  -d '{"uri": "http://localhost:9080", "force": true}'
```

### Invoke Handlers

**Greeter (stateless service):**
```bash
# Simple greeting — exercises ctx.run
curl localhost:8080/Greeter/greet \
  -H 'content-type: application/json' -d '"World"'
# → "Hello, World!"

# Greeting with cross-service call — exercises ctx.object_call, ctx.get, ctx.set
curl localhost:8080/Greeter/greetAndRemember \
  -H 'content-type: application/json' -d '"Alice"'
# → "Hello, Alice! (greeted 1 times)"
```

**Counter (virtual object — requires key in URL):**
```bash
curl localhost:8080/Counter/my-counter/add \
  -H 'content-type: application/json' -d '3'
# → {"oldValue":0,"newValue":3}

curl localhost:8080/Counter/my-counter/get \
  -H 'content-type: application/json' -d 'null'
# → 3

curl localhost:8080/Counter/my-counter/reset \
  -H 'content-type: application/json' -d 'null'
# → null
```

**Signup (workflow — requires key in URL):**
```bash
curl localhost:8080/Signup/user1/run \
  -H 'content-type: application/json' -d '"user@example.com"' \
  -H 'idempotency-key: signup-1'
# → {"userId":"user_user_example_com","email":"user@example.com"}

curl localhost:8080/Signup/user1/status \
  -H 'content-type: application/json' -d 'null'
# → "completed"
```

### Health Check

```bash
# Direct to Falcon (HTTP/2, needs special curl flag or go through Restate)
curl --http2-prior-knowledge http://localhost:9080/health
# → {"status":"ok"}
```

### Troubleshooting

- **Falcon not responding to curl**: Falcon uses HTTP/2. Use `--http2-prior-knowledge` or go
  through the Restate ingress (port 8080) which handles protocol negotiation.
- **Worker crashes on startup**: Check Falcon logs (JSON to stdout). Common cause: Sorbet runtime
  `NameError` from eager sig evaluation — ensure all types referenced in sigs are loaded.
- **Port stuck after crash**: `lsof -ti :9080 | xargs kill -9`
- **Restate can't reach Falcon**: If Restate runs in Docker, bind Falcon to `0.0.0.0` not
  `localhost`, and use the host machine's IP in the registration URI.

## Test Services (`test-services/`)

The `test-services/` directory contains integration test services ported from the Python SDK's
`test-services/`. These are designed to run against the
[sdk-test-suite](https://github.com/restatedev/sdk-test-suite) (JVM-based e2e verification runner).

### Structure

```
test-services/
├── Dockerfile             # Multi-stage build (compile native ext → run Falcon)
├── Gemfile                # Points to SDK via path: ".."
├── config.ru              # Rack entry point
├── services.rb            # Service registry (supports SERVICES env var filtering)
├── entrypoint.sh          # Docker entrypoint (runs Falcon)
├── exclusions.yaml        # Excluded services/handlers for test suite
├── .env                   # Default env vars
└── services/
    ├── counter.rb         # Counter VirtualObject (reset, get, add, addThenFail)
    ├── list_object.rb     # ListObject VirtualObject (append, get, clear)
    ├── map_object.rb      # MapObject VirtualObject (set, get, clearAll)
    ├── failing.rb         # Failing VirtualObject (terminal errors, retry policies)
    ├── non_determinism.rb # NonDeterministic VirtualObject (deliberate non-determinism)
    └── test_utils.rb      # TestUtilsService (echo, headers, rawEcho, side effects)
```

### Ported Services

| Service | Type | Handlers |
|---------|------|----------|
| Counter | VirtualObject | reset, get, add, addThenFail |
| ListObject | VirtualObject | append, get, clear |
| MapObject | VirtualObject | set, get, clearAll |
| Failing | VirtualObject | terminallyFailingCall, callTerminallyFailingCall, failingCallWithEventualSuccess, terminallyFailingSideEffect, sideEffectSucceedsAfterGivenAttempts, sideEffectFailsAfterGivenAttempts |
| NonDeterministic | VirtualObject | setDifferentKey, backgroundInvokeWithDifferentTargets, callDifferentMethod, eitherSleepOrCall |
| TestUtilsService | Service | echo, uppercaseEcho, echoHeaders, rawEcho, countExecutedSideEffects |

### Not Yet Ported (missing SDK features)

| Service | Blocked On |
|---------|------------|
| AwakeableHolder | `ctx.awakeable`, `ctx.resolve_awakeable` |
| BlockAndWaitWorkflow | `ctx.promise` |
| CancelTestRunner/BlockingService | `ctx.awakeable`, cancellation |
| KillTestRunner/Singleton | `ctx.awakeable` |
| Proxy | `ctx.generic_call`, `ctx.generic_send` |
| Interpreter (L0/L1/L2), Helper | Awakeables, promises, combinators |
| VirtualObjectCommandInterpreter | Awakeables, promises, combinators |
| TestUtilsService.sleepConcurrently | Concurrent sleep handles |
| TestUtilsService.cancelInvocation | `ctx.cancel_invocation` |

### Running Locally

```bash
cd test-services
bundle install
bundle exec falcon serve --bind http://localhost:9080
```

### Running with Docker

The Dockerfile must be built from the **repo root** (it copies the SDK source):

```bash
docker build -f test-services/Dockerfile -t restate-ruby-test-services .
docker run -p 9080:9080 restate-ruby-test-services
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `SERVICES` | Comma-separated list of service names to register (default: all) |
| `E2E_REQUEST_SIGNING_ENV` | Identity signing key for request verification |
| `PORT` | Listen port (default: 9080) |
| `RESTATE_CORE_LOG` | Rust core log level (default: debug) |
| `RESTATE_LOGGING` | Alias for `RESTATE_CORE_LOG` (used by e2e runner) |

## Important Learnings

### 1. `read_partial` vs `read` on Falcon's `rack.input`

Falcon's `rack.input` is a `Protocol::Rack::Input` backed by `IO::Stream::Readable`.

- **`read(n)`** loops calling `fill_read_buffer` until the buffer has `n` bytes or EOF. On a
  streaming HTTP/2 body where initial data is ~250 bytes and the stream stays open,
  `read(16384)` **blocks forever**.
- **`read_partial(n)`** calls `fill_read_buffer` once and returns whatever is available.

This is the Ruby equivalent of Python's ASGI `receive()` which naturally returns chunks as they
arrive.

### 2. `take_output` Can Return Empty Strings

The Rust VM's `take_output` returns `TakeOutputResult::Buffer(bytes)` where bytes can be empty
(0 length). The Magnus binding converts this to Ruby `""`. In Ruby, empty string is **truthy**,
so naive checks like `break unless output` create infinite loops.

**Always use**: `break if output.nil? || output.empty?`

This differs from Python where `if output:` is false for both `None` and `b""`.

This applies in two places:
- `ServerContext#flush_output` (progress loop output drain)
- `Server#process_invocation` (final output drain after handler completes)

### 3. Async::Queue, Not Thread::Queue

The SDK runs on Async fibers, not OS threads. `Thread::Queue` blocks the OS thread (and the
entire event loop). `Async::Queue` yields the fiber, allowing other fibers to run.

- `Async::Queue` uses `enqueue` / `dequeue` (not `push` / `pop`).
- The `input_queue` multiplexes several signal types: `String` (body chunk), `:eof`,
  `:disconnected`, `:run_completed`.

### 4. Magnus Init Symbol

The native extension init function must specify the exact module name:
```rust
#[magnus::init(name = "restate_internal")]
```
Without this, Magnus derives the symbol from the Cargo crate name, which may not match what
Ruby expects from `require "restate_internal"`.

### 5. Binary String Encoding

All byte buffers passed to the VM must be ASCII-8BIT encoded. Call `.b` on strings before
passing them to `notify_input`, `sys_set_state`, `sys_write_output_success`, etc.

### 6. Error Handling in Handlers

`SuspendedError` and `InternalError` are internal control flow exceptions. User handlers that
use bare `rescue => e` will accidentally catch these. The `ServerContext#enter` method walks the
exception cause chain to detect wrapped internal exceptions.

### 7. Falcon Process Management

Falcon forks worker processes. When a worker dies (e.g., health check timeout after 30s), the
parent process survives and holds the port. To fully restart:
```bash
lsof -ti :9080 | xargs kill -9
```

Use `-n 1` flag for single worker during development.

## VM State Machine

The VM is a synchronous state machine. It does not do I/O itself. The SDK drives it:

1. Feed input bytes → `notify_input(bytes)` / `notify_input_closed()`
2. Check readiness → `is_ready_to_execute()`
3. Get invocation → `sys_input()`
4. Issue syscalls → `sys_get_state`, `sys_run`, `sys_call`, etc. (returns handles)
5. Drive progress → `do_progress(handles)` (tells you what to do next)
6. Collect results → `take_notification(handle)` (gets completed values)
7. Drain output → `take_output()` (gets bytes to send back over HTTP/2)
8. Finish → `sys_write_output_success/failure` then `sys_end`

The VM is wrapped in `RefCell<CoreVM>` — it is not thread-safe. All access must happen within
the same fiber chain (which is guaranteed by Async's cooperative scheduling).
