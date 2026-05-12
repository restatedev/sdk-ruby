# frozen_string_literal: true

require 'spec_helper'
require 'restate/handler'

# Thin wrapper to test the private with_outbound_middleware method in isolation,
# without needing a VM, invocation, or Restate runtime.
class OutboundMiddlewareHarness
  def initialize(outbound_middleware)
    @outbound_middleware = outbound_middleware
  end

  def run(service, handler, headers, handler_meta: nil, &action)
    with_outbound_middleware(service, handler, headers, handler_meta: handler_meta, &action)
  end

  private

  # Extracted verbatim from ServerContext to test in isolation.
  def with_outbound_middleware(service, handler, headers, handler_meta: nil, &action)
    return action.call(headers) if @outbound_middleware.empty?

    h = headers || {}
    previous_meta = Thread.current[:restate_outbound_handler_meta]
    Thread.current[:restate_outbound_handler_meta] = handler_meta
    chain = ->(hdrs) { action.call(hdrs) }
    @outbound_middleware.reverse_each do |mw|
      prev = chain
      chain = ->(hdrs) { mw.call(service, handler, hdrs) { prev.call(hdrs) } }
    end
    chain.call(h)
  ensure
    Thread.current[:restate_outbound_handler_meta] = previous_meta
  end
end

# Simple spy middleware that records what it saw during the chain.
class SpyMiddleware
  attr_reader :observed_meta, :called

  def initialize
    @called = false
    @observed_meta = nil
  end

  def call(_service, _handler, headers)
    @called = true
    @observed_meta = Thread.current[:restate_outbound_handler_meta]
    yield
  end
end

RSpec.describe 'ServerContext#with_outbound_middleware handler_meta plumbing' do
  def make_handler(kind:, service_name: 'TestVO')
    Restate::Handler.new(
      service_tag: Restate::ServiceTag.new(kind: 'object', name: service_name),
      handler_io: nil,
      kind: kind,
      name: 'test_handler',
      callable: nil,
      arity: 0
    )
  end

  after do
    Thread.current[:restate_outbound_handler_meta] = nil
  end

  it 'exposes handler_meta to middleware via thread-local' do
    spy = SpyMiddleware.new
    harness = OutboundMiddlewareHarness.new([spy])
    meta = make_handler(kind: 'exclusive')

    harness.run('SomeService', 'some_handler', {}, handler_meta: meta) { |_hdrs| :ok }

    expect(spy.called).to be true
    expect(spy.observed_meta).to eq(meta)
  end

  it 'sets handler_meta to nil when not provided' do
    spy = SpyMiddleware.new
    harness = OutboundMiddlewareHarness.new([spy])

    harness.run('SomeService', 'some_handler', {}) { |_hdrs| :ok }

    expect(spy.observed_meta).to be_nil
  end

  it 'cleans up handler_meta after the chain completes' do
    spy = SpyMiddleware.new
    harness = OutboundMiddlewareHarness.new([spy])
    meta = make_handler(kind: 'exclusive')

    harness.run('SomeService', 'some_handler', {}, handler_meta: meta) { |_hdrs| :ok }

    expect(Thread.current[:restate_outbound_handler_meta]).to be_nil
  end

  it 'restores previous handler_meta after nested calls' do
    spy_inner = SpyMiddleware.new
    inner_harness = OutboundMiddlewareHarness.new([spy_inner])
    spy_outer = SpyMiddleware.new
    outer_harness = OutboundMiddlewareHarness.new([spy_outer])

    outer_meta = make_handler(kind: 'exclusive', service_name: 'OuterVO')
    inner_meta = make_handler(kind: 'shared', service_name: 'InnerVO')

    outer_harness.run('OuterVO', 'outer', {}, handler_meta: outer_meta) do |_hdrs|
      expect(Thread.current[:restate_outbound_handler_meta]).to eq(outer_meta)

      inner_harness.run('InnerVO', 'inner', {}, handler_meta: inner_meta) do |_hdrs2|
        expect(Thread.current[:restate_outbound_handler_meta]).to eq(inner_meta)
        :inner_ok
      end

      expect(Thread.current[:restate_outbound_handler_meta]).to eq(outer_meta)
      :outer_ok
    end

    expect(Thread.current[:restate_outbound_handler_meta]).to be_nil
  end

  it 'cleans up handler_meta even when middleware raises' do
    error_mw = Class.new do
      def call(_service, _handler, _headers)
        raise 'middleware boom'
      end
    end.new
    harness = OutboundMiddlewareHarness.new([error_mw])
    meta = make_handler(kind: 'exclusive')

    expect do
      harness.run('SomeService', 'handler', {}, handler_meta: meta) { |_hdrs| :ok }
    end.to raise_error(RuntimeError, 'middleware boom')

    expect(Thread.current[:restate_outbound_handler_meta]).to be_nil
  end

  it 'calls action directly when no middleware is registered' do
    harness = OutboundMiddlewareHarness.new([])

    action_called = false
    harness.run('SomeService', 'handler', { 'x-existing' => 'val' }) do |hdrs|
      action_called = true
      expect(hdrs['x-existing']).to eq('val')
      :ok
    end

    expect(action_called).to be true
  end

  it 'passes headers through the middleware chain correctly' do
    tag_mw = Class.new do
      def call(_service, _handler, headers)
        headers['x-tagged'] = 'yes'
        yield
      end
    end.new
    harness = OutboundMiddlewareHarness.new([tag_mw])

    received_headers = nil
    harness.run('Svc', 'handler', {}) do |hdrs|
      received_headers = hdrs
      :ok
    end

    expect(received_headers['x-tagged']).to eq('yes')
  end
end
