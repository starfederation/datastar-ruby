# frozen_string_literal: true

require 'datastar'
require 'rack'

RSpec.describe Datastar::EncodingNegotiation do
  after { described_class.reset_brotli_cache! }

  describe '.negotiate' do
    it 'returns nil when compression is disabled' do
      request = build_request('Accept-Encoding' => 'br, gzip')
      result = described_class.negotiate(request, preferred: :br, enabled: false)
      expect(result).to be_nil
    end

    it 'returns nil when no Accept-Encoding header' do
      request = build_request
      result = described_class.negotiate(request, preferred: :br, enabled: true)
      expect(result).to be_nil
    end

    it 'returns :gzip when client accepts gzip' do
      request = build_request('Accept-Encoding' => 'gzip')
      result = described_class.negotiate(request, preferred: :gzip, enabled: true)
      expect(result).to eq(:gzip)
    end

    it 'returns preferred encoding when both are accepted' do
      request = build_request('Accept-Encoding' => 'br, gzip')
      if described_class.brotli_available?
        result = described_class.negotiate(request, preferred: :br, enabled: true)
        expect(result).to eq(:br)
      else
        result = described_class.negotiate(request, preferred: :br, enabled: true)
        expect(result).to eq(:gzip)
      end
    end

    it 'falls back to gzip when brotli preferred but unavailable' do
      # Simulate brotli being unavailable
      allow(described_class).to receive(:brotli_available?).and_return(false)
      described_class.reset_brotli_cache!

      request = build_request('Accept-Encoding' => 'br, gzip')
      result = described_class.negotiate(request, preferred: :br, enabled: true)
      expect(result).to eq(:gzip)
    end

    it 'returns nil when client encoding not in enabled list' do
      request = build_request('Accept-Encoding' => 'br')
      result = described_class.negotiate(request, preferred: :br, enabled: [:gzip])
      expect(result).to be_nil
    end

    it 'respects enabled array' do
      request = build_request('Accept-Encoding' => 'br, gzip')
      result = described_class.negotiate(request, preferred: :br, enabled: [:gzip])
      expect(result).to eq(:gzip)
    end

    it 'returns nil when Accept-Encoding has q=0 for all' do
      request = build_request('Accept-Encoding' => 'gzip;q=0, br;q=0')
      result = described_class.negotiate(request, preferred: :br, enabled: true)
      expect(result).to be_nil
    end

    it 'handles Accept-Encoding with quality values' do
      request = build_request('Accept-Encoding' => 'gzip;q=1.0, br;q=0.5')
      result = described_class.negotiate(request, preferred: :gzip, enabled: true)
      expect(result).to eq(:gzip)
    end
  end

  describe '.brotli_available?' do
    it 'returns a boolean' do
      described_class.reset_brotli_cache!
      expect(described_class.brotli_available?).to be(true).or be(false)
    end

    it 'memoizes the result' do
      described_class.reset_brotli_cache!
      result1 = described_class.brotli_available?
      result2 = described_class.brotli_available?
      expect(result1).to eq(result2)
    end
  end

  private

  def build_request(headers = {})
    env = Rack::MockRequest.env_for('/', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    Rack::Request.new(env)
  end
end
