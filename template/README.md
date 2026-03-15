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
