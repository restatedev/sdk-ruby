[![Documentation](https://img.shields.io/badge/doc-reference-blue)](https://docs.restate.dev)
[![Examples](https://img.shields.io/badge/view-examples-blue)](https://github.com/restatedev/examples)
[![Discord](https://img.shields.io/discord/1128210118216007792?logo=discord)](https://discord.gg/skW3AZ6uGd)
[![Twitter](https://img.shields.io/twitter/follow/restatedev.svg?style=social&label=Follow)](https://twitter.com/intent/follow?screen_name=restatedev)

# Restate Ruby SDK

> **Note:** This SDK is currently under active development. APIs may change between releases.

[Restate](https://restate.dev/) is a system for easily building resilient applications using *distributed durable async/await*. This repository contains the Restate SDK for writing services in **Ruby**.

```ruby
require 'restate'

class Greeter < Restate::Service
  handler def greet(name)
    Restate.run_sync('build-greeting') { "Hello, #{name}!" }
  end
end

class Counter < Restate::VirtualObject
  state :count, default: 0

  handler def add(addend)
    self.count += addend
  end

  shared def get
    count
  end
end
```

## Community

* [Join our online community](https://discord.gg/skW3AZ6uGd) for help, sharing feedback and talking to the community.
* [Check out our documentation](https://docs.restate.dev) to get quickly started!
* [Follow us on Twitter](https://twitter.com/restatedev) for staying up to date.
* [Create a GitHub issue](https://github.com/restatedev/sdk-ruby/issues) for requesting a new feature or reporting a problem.
* [Visit our GitHub org](https://github.com/restatedev) for exploring other repositories.

## Using the SDK

**Prerequisites:**
- Ruby >= 3.1

For brand-new projects, we recommend using the [Restate Ruby Template](template/):

```shell
cp -r template/ my-restate-service
cd my-restate-service
bundle install
```

Or add the gem to an existing project:

```shell
gem install restate-sdk
```

### Typed handlers with Dry::Struct

Use [dry-struct](https://dry-rb.org/gems/dry-struct/) for typed input/output with automatic JSON Schema generation:

```ruby
require 'restate'
require 'dry-struct'

module Types
  include Dry.Types()
end

class RegistrationRequest < Dry::Struct
  attribute :event_name, Types::String
  attribute :attendee, Types::String
  attribute :num_guests, Types::Integer
  attribute? :note, Types::String       # optional attribute
end

class RegistrationResponse < Dry::Struct
  attribute :registration_id, Types::String
  attribute :status, Types::String
end

class EventService < Restate::Service
  handler :register, input: RegistrationRequest, output: RegistrationResponse
  def register(request)
    registration_id = Restate.run_sync('create-registration') do
      "reg_#{request.event_name}_#{rand(10_000)}"
    end

    RegistrationResponse.new(
      registration_id: registration_id,
      status: 'confirmed'
    )
  end
end
```

See more in the [User Guide](docs/USER_GUIDE.md) and the [examples/](examples/) directory.

## Contributing

We're excited if you join the Restate community and start contributing!
Whether it is feature requests, bug reports, ideas & feedback or PRs, we appreciate any and all contributions.
We know that your time is precious and, therefore, deeply value any effort to contribute!

### Local development

* Ruby >= 3.1
* [Rust toolchain](https://rustup.rs/)
* Docker (for integration tests)
* Java 21+ (for sdk-test-suite integration tests)

Install dependencies and build:

```shell
bundle install
make build
```

Run the full verification suite (build, lint, typecheck, tests):

```shell
make verify
```

Run integration tests (requires Docker + Java 21+):

```shell
make test-integration
```

## Releasing the package

1. Pull latest main:

    ```shell
    git checkout main && git pull
    ```

2. Bump the version in **both** files:
    - `lib/restate/version.rb` — e.g. `VERSION = '0.5.0'`
    - `ext/restate_internal/Cargo.toml` — e.g. `version = "0.5.0"`

3. Update the lock file and verify:

    ```shell
    make build
    ```

4. Commit, tag, and push:

    ```shell
    git add -A
    git commit -m "Release v0.5.0"
    git tag -m "Release v0.5.0" v0.5.0
    git push origin main v0.5.0
    ```

The [release workflow](.github/workflows/release.yml) will build pre-compiled native gems for all platforms (x86_64/aarch64 Linux, macOS, musl) and publish them to [RubyGems](https://rubygems.org/gems/restate-sdk).
