# frozen_string_literal: true

require 'spec_helper'
require 'restate/client'

RSpec.describe Restate::Client do
  let(:client) { described_class.new }
  let(:http) { instance_double(Net::HTTP) }
  let(:response) { Net::HTTPNoContent.new('1.1', '204', 'No Content') }

  before do
    allow(response).to receive(:body).and_return(nil)
    allow(Net::HTTP).to receive(:start).and_yield(http)
  end

  it 'sends false as the JSON body when resolving an awakeable' do
    expect(http).to receive(:request)
      .with(have_attributes(path: '/restate/awakeables/awakeable-id/resolve', body: 'false'))
      .and_return(response)

    client.resolve_awakeable('awakeable-id', false)
  end

  it 'omits the request body when resolving an awakeable with nil' do
    expect(http).to receive(:request)
      .with(have_attributes(path: '/restate/awakeables/awakeable-id/resolve', body: nil))
      .and_return(response)

    client.resolve_awakeable('awakeable-id', nil)
  end
end
