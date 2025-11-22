# frozen_string_literal: true

RSpec.describe Datastar::AsyncExecutor do
  it 'removes Connection header from response' do
    executor = described_class.new
    response = Rack::Response.new(nil, 200, { 'Connection' => 'keep-alive'})
    executor.prepare(response)
    expect(response.headers.key?('Connection')).to be(false)
  end
end
