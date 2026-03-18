# Restate Ruby Service Template

A minimal template for building [Restate](https://restate.dev/) services in Ruby.

## Prerequisites

- Ruby >= 3.1
- [Restate Server](https://docs.restate.dev/develop/local_dev) running locally

## Getting started

Install dependencies:

```shell
bundle install
```

Start the service:

```shell
bundle exec falcon serve --bind http://localhost:9080
```

Register with Restate:

```shell
restate deployments register http://localhost:9080
```

Invoke the greeter:

```shell
curl localhost:8080/Greeter/greet \
  -H 'content-type: application/json' \
  -d '{"name": "World"}'
```

## Verification

Run the full verification suite (generate types, lint, typecheck):

```shell
make verify
```

Individual targets:

```shell
make tapioca    # Generate typed handler signatures
make lint       # Run Rubocop
make typecheck  # Run Sorbet type checker
make lint-fix   # Auto-fix lint offenses
```

## IDE Code Completion

The SDK ships a [Tapioca](https://github.com/Shopify/tapioca) DSL compiler that generates
[Sorbet](https://sorbet.org/) type signatures for your handlers — giving your IDE full code
completion for `ctx` and typed input/output parameters with zero annotations in your code.

Run `make tapioca` (or `bundle exec tapioca dsl`) whenever you add or rename handlers.
Commit the generated `sorbet/rbi/dsl/` files to version control so the whole team benefits.
