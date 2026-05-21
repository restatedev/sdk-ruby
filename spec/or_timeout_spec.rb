# frozen_string_literal: true

require 'spec_helper'
require 'restate'

# Unit coverage for +DurableFuture#or_timeout+ and
# +DurableCallFuture#or_timeout+. Stubs the +Restate+ module-level
# helpers (+sleep+, +wait_any+) so the spec doesn't need a live VM —
# this is intentionally an SDK-shape check, not an end-to-end
# integration. The +test-services/+ suite covers the live-VM path.
RSpec.describe Restate::DurableFuture do
  # Minimal fake context that just records calls. Real Server::Context
  # is too heavy for this spec — we only need +resolve_handle+ and
  # +completed?+ to respond.
  let(:ctx) { double('ctx', resolve_handle: 'ignored', completed?: false) }

  describe '#or_timeout' do
    context 'when the future completes before the sleep' do
      it "returns the future's value" do
        future = described_class.new(ctx, :handle_a)
        sleep_future = described_class.new(ctx, :handle_sleep)

        allow(Restate).to receive(:sleep).with(5).and_return(sleep_future)
        allow(Restate).to receive(:wait_any) do
          # Race outcome: the work future wins.
          allow(future).to receive(:completed?).and_return(true)
          allow(future).to receive(:await).and_return('done')
          nil
        end

        expect(future.or_timeout(5)).to eq('done')
      end
    end

    context 'when the sleep wins the race' do
      it 'raises Restate::TimeoutError' do
        future = described_class.new(ctx, :handle_a)
        sleep_future = described_class.new(ctx, :handle_sleep)

        allow(Restate).to receive(:sleep).with(5).and_return(sleep_future)
        allow(Restate).to receive(:wait_any) do
          # Race outcome: the sleep wins; the work future stays incomplete.
          allow(future).to receive(:completed?).and_return(false)
          nil
        end

        expect { future.or_timeout(5) }.to raise_error(Restate::TimeoutError)
      end

      it 'attaches HTTP status 408 (Request Timeout)' do
        future = described_class.new(ctx, :handle_a)
        allow(Restate).to receive(:sleep).and_return(described_class.new(ctx, :sleep))
        allow(Restate).to receive(:wait_any) do
          allow(future).to receive(:completed?).and_return(false)
          nil
        end

        future.or_timeout(5)
      rescue Restate::TimeoutError => e
        expect(e.status_code).to eq(408)
      end
    end
  end
end

RSpec.describe Restate::DurableCallFuture do
  let(:ctx) do
    double('ctx', resolve_handle: 'inv_xyz', completed?: false, cancel_invocation: nil)
  end

  def build_call_future
    described_class.new(ctx, :result_handle, :invocation_id_handle, output_serde: nil)
  end

  # Matches TS/Java SDKs: timeout never auto-cancels the underlying call.
  # Users who want that behavior rescue +TimeoutError+ and call +#cancel+.
  describe '#or_timeout' do
    context 'when the call completes before the sleep' do
      it "returns the call's value and does not cancel" do
        future = build_call_future
        sleep_future = Restate::DurableFuture.new(ctx, :handle_sleep)

        allow(Restate).to receive(:sleep).with(5).and_return(sleep_future)
        allow(Restate).to receive(:wait_any) do
          allow(future).to receive(:completed?).and_return(true)
          allow(future).to receive(:await).and_return({ 'ok' => true })
          nil
        end

        expect(future.or_timeout(5)).to eq({ 'ok' => true })
        expect(ctx).not_to have_received(:cancel_invocation)
      end
    end

    context 'when the sleep wins the race' do
      it 'raises TimeoutError without cancelling the remote invocation' do
        future = build_call_future
        sleep_future = Restate::DurableFuture.new(ctx, :handle_sleep)

        allow(Restate).to receive(:sleep).with(5).and_return(sleep_future)
        allow(Restate).to receive(:wait_any) do
          allow(future).to receive(:completed?).and_return(false)
          nil
        end

        expect { future.or_timeout(5) }.to raise_error(Restate::TimeoutError)
        expect(ctx).not_to have_received(:cancel_invocation)
      end
    end
  end
end

RSpec.describe Restate::TimeoutError do
  it 'inherits from TerminalError so user rescue blocks catch it uniformly' do
    expect(described_class.ancestors).to include(Restate::TerminalError)
  end

  it 'defaults to HTTP status 408 (Request Timeout) matching the TS SDK' do
    expect(described_class.new.status_code).to eq(408)
  end

  it 'has a meaningful default message' do
    expect(described_class.new.message).to eq('Timeout occurred')
  end
end
