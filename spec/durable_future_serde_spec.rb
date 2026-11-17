# frozen_string_literal: true

require 'spec_helper'
require 'restate/errors'
require 'restate/durable_future'

# A serde failure is not a TerminalError: it is cached and re-raised on every
# await, never a silent nil.
RSpec.describe Restate::DurableFuture do
  let(:ctx) { double('ctx', resolve_handle: 'raw') }
  let(:serde) { double('serde') }

  it 'keeps raising when deserialization fails on every await' do
    allow(serde).to receive(:deserialize).and_raise(ArgumentError, 'bad payload')
    future = described_class.new(ctx, :handle, serde: serde)

    expect { future.await }.to raise_error(ArgumentError, 'bad payload')
    expect { future.await }.to raise_error(ArgumentError, 'bad payload')
  end

  it 'caches a TerminalError across awaits' do
    allow(ctx).to receive(:resolve_handle).and_raise(Restate::TerminalError.new('boom'))
    future = described_class.new(ctx, :handle)

    expect { future.await }.to raise_error(Restate::TerminalError)
    expect { future.await }.to raise_error(Restate::TerminalError)
    expect(ctx).to have_received(:resolve_handle).once
  end
end

RSpec.describe Restate::DurableCallFuture do
  it 'keeps raising when output deserialization fails on every await' do
    ctx = double('ctx', resolve_handle: 'raw')
    serde = double('serde')
    allow(serde).to receive(:deserialize).and_raise(ArgumentError, 'bad payload')
    future = described_class.new(ctx, :result, :inv, output_serde: serde)

    expect { future.await }.to raise_error(ArgumentError, 'bad payload')
    expect { future.await }.to raise_error(ArgumentError, 'bad payload')
  end
end
