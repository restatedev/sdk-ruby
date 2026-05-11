# frozen_string_literal: true

require 'spec_helper'
require 'set'
require 'restate/errors'
require 'restate/handler'
require 'restate/middleware/deadlock_detection'

DD = Restate::Middleware::DeadlockDetection

RSpec.describe DD do
  let(:inbound) { DD::Inbound.new }
  let(:outbound) { DD::Outbound.new }

  before do
    DD.held_locks = Set.new
    Thread.current[:restate_outbound_handler_meta] = nil
  end

  after do
    DD.held_locks = Set.new
    Thread.current[:restate_outbound_handler_meta] = nil
  end

  def make_handler(service_kind:, service_name:, handler_name:, handler_kind:)
    Restate::Handler.new(
      service_tag: Restate::ServiceTag.new(kind: service_kind, name: service_name),
      handler_io: nil,
      kind: handler_kind,
      name: handler_name,
      callable: nil,
      arity: 0
    )
  end

  def make_ctx(headers: {}, key: nil)
    request = double('request', headers: headers)
    ctx = double('ctx', request: request)
    allow(ctx).to receive(:key).and_return(key) if key
    allow(ctx).to receive(:respond_to?).with(:key).and_return(!key.nil?)
    ctx
  end

  def encode_locks(*pairs)
    DD.encode_header(Set.new(pairs))
  end

  describe 'wire format encoding' do
    it 'round-trips service and key through base64url' do
      encoded = DD.encode_lock('Account', 'alice')
      svc, key = DD.decode_lock(encoded)
      expect(svc).to eq('Account')
      expect(key).to eq('alice')
    end

    it 'handles keys with special characters' do
      encoded = DD.encode_lock('MyService', 'key:with,special.chars/and=more')
      svc, key = DD.decode_lock(encoded)
      expect(svc).to eq('MyService')
      expect(key).to eq('key:with,special.chars/and=more')
    end

    it 'handles unicode service names and keys' do
      encoded = DD.encode_lock('Überservice', '日本語キー')
      svc, key = DD.decode_lock(encoded)
      expect(svc).to eq('Überservice')
      expect(key).to eq('日本語キー')
    end

    it 'returns nil for malformed lock entries' do
      expect(DD.decode_lock('nope')).to be_nil
    end

    it 'encodes multiple locks into a comma-separated header' do
      header = DD.encode_header(Set.new([%w[A k1], %w[B k2]]))
      decoded = DD.decode_header(header)
      expect(decoded).to include(%w[A k1])
      expect(decoded).to include(%w[B k2])
    end
  end

  describe DD::Inbound do
    let(:vo_exclusive) do
      make_handler(service_kind: 'object', service_name: 'Account',
                   handler_name: 'transfer', handler_kind: 'exclusive')
    end

    let(:vo_shared) do
      make_handler(service_kind: 'object', service_name: 'Account',
                   handler_name: 'get_balance', handler_kind: 'shared')
    end

    let(:basic_service) do
      make_handler(service_kind: 'service', service_name: 'EmailService',
                   handler_name: 'send_email', handler_kind: nil)
    end

    it 'allows calls with no held locks' do
      ctx = make_ctx(headers: {}, key: 'alice')
      result = inbound.call(vo_exclusive, ctx) { :ok }
      expect(result).to eq(:ok)
    end

    it 'allows calls to a different VO key' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(%w[Account bob]) },
        key: 'alice'
      )
      result = inbound.call(vo_exclusive, ctx) { :ok }
      expect(result).to eq(:ok)
    end

    it 'raises DeadlockError when calling same VO key' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(%w[Account alice]) },
        key: 'alice'
      )

      expect do
        inbound.call(vo_exclusive, ctx) { :ok }
      end.to raise_error(DD::DeadlockError) { |e|
        expect(e.message).to include('Deadlock detected')
        expect(e.message).to include('Account')
        expect(e.message).to include('alice')
        expect(e.status_code).to eq(409)
      }
    end

    it 'allows shared handlers on the same VO key (no deadlock)' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(%w[Account alice]) },
        key: 'alice'
      )

      result = inbound.call(vo_shared, ctx) { :ok }
      expect(result).to eq(:ok)
    end

    it 'tracks exclusive locks through the chain' do
      ctx = make_ctx(headers: {}, key: 'alice')

      inbound.call(vo_exclusive, ctx) do
        locks = DD.held_locks
        expect(locks).to include(%w[Account alice])
        :ok
      end
    end

    it 'does not add locks for shared handlers' do
      ctx = make_ctx(headers: {}, key: 'alice')

      inbound.call(vo_shared, ctx) do
        locks = DD.held_locks
        expect(locks).not_to include(%w[Account alice])
        :ok
      end
    end

    it 'restores previous locks after handler completes' do
      previous = Set.new([%w[OtherVO other-key]])
      DD.held_locks = previous

      ctx = make_ctx(headers: {}, key: 'alice')
      inbound.call(vo_exclusive, ctx) { :ok }

      expect(DD.held_locks).to eq(previous)
    end

    it 'restores previous locks even on error' do
      previous = Set.new([%w[OtherVO other-key]])
      DD.held_locks = previous

      ctx = make_ctx(headers: {}, key: 'alice')

      expect do
        inbound.call(vo_exclusive, ctx) { raise 'boom' }
      end.to raise_error(RuntimeError, 'boom')

      expect(DD.held_locks).to eq(previous)
    end

    it 'skips detection for basic services' do
      ctx = make_ctx(headers: { DD::HEADER => encode_locks(%w[EmailService something]) })

      result = inbound.call(basic_service, ctx) { :ok }
      expect(result).to eq(:ok)
    end

    it 'accumulates locks from incoming header' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(%w[OtherVO other-key]) },
        key: 'alice'
      )

      inbound.call(vo_exclusive, ctx) do
        locks = DD.held_locks
        expect(locks).to include(%w[OtherVO other-key])
        expect(locks).to include(%w[Account alice])
        :ok
      end
    end

    it 'handles multiple locks in header' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(%w[ServiceA key1], %w[ServiceB key2]) },
        key: 'alice'
      )

      inbound.call(vo_exclusive, ctx) do
        locks = DD.held_locks
        expect(locks).to include(%w[ServiceA key1])
        expect(locks).to include(%w[ServiceB key2])
        expect(locks).to include(%w[Account alice])
        :ok
      end
    end

    it 'handles keys containing colons and commas' do
      ctx = make_ctx(
        headers: { DD::HEADER => encode_locks(['Account', 'key:with,special']) },
        key: 'other'
      )

      inbound.call(vo_exclusive, ctx) do
        locks = DD.held_locks
        expect(locks).to include(['Account', 'key:with,special'])
        :ok
      end
    end
  end

  describe DD::Outbound do
    it 'injects held locks as base64-encoded header' do
      DD.held_locks = Set.new([%w[SomeVO some-key]])
      headers = {}

      outbound.call('OtherVO', 'some_handler', headers) { :ok }

      decoded = DD.decode_header(headers[DD::HEADER])
      expect(decoded).to include(%w[SomeVO some-key])
    end

    it 'does not inject header when no locks held' do
      headers = {}

      outbound.call('SomeVO', 'some_handler', headers) { :ok }

      expect(headers).not_to have_key(DD::HEADER)
    end

    it 'raises DeadlockError when calling same service that holds lock (no metadata)' do
      DD.held_locks = Set.new([%w[MyVO my-key]])
      headers = {}

      expect do
        outbound.call('MyVO', 'some_handler', headers) { :ok }
      end.to raise_error(DD::DeadlockError) { |e|
        expect(e.message).to include('Deadlock detected')
        expect(e.message).to include('MyVO')
        expect(e.status_code).to eq(409)
      }
    end

    it 'raises DeadlockError when target handler is exclusive' do
      DD.held_locks = Set.new([%w[MyVO my-key]])
      Thread.current[:restate_outbound_handler_meta] = make_handler(
        service_kind: 'object', service_name: 'MyVO',
        handler_name: 'do_something', handler_kind: 'exclusive'
      )
      headers = {}

      expect do
        outbound.call('MyVO', 'do_something', headers) { :ok }
      end.to raise_error(DD::DeadlockError)
    end

    it 'allows calls to a shared handler on the same service' do
      DD.held_locks = Set.new([%w[MyVO my-key]])
      Thread.current[:restate_outbound_handler_meta] = make_handler(
        service_kind: 'object', service_name: 'MyVO',
        handler_name: 'read_state', handler_kind: 'shared'
      )
      headers = {}

      result = outbound.call('MyVO', 'read_state', headers) { :ok }
      expect(result).to eq(:ok)
      decoded = DD.decode_header(headers[DD::HEADER])
      expect(decoded).to include(%w[MyVO my-key])
    end

    it 'allows calls to a different service' do
      DD.held_locks = Set.new([%w[MyVO my-key]])
      headers = {}

      result = outbound.call('OtherService', 'some_handler', headers) { :ok }
      expect(result).to eq(:ok)
    end

    it 'includes all held locks in header' do
      DD.held_locks = Set.new([%w[ServiceA key1], %w[ServiceB key2]])
      headers = {}

      outbound.call('ServiceC', 'handler', headers) { :ok }

      decoded = DD.decode_header(headers[DD::HEADER])
      expect(decoded).to include(%w[ServiceA key1])
      expect(decoded).to include(%w[ServiceB key2])
    end
  end
end
