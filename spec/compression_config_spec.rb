# frozen_string_literal: true

require 'datastar'
require 'rack'

RSpec.describe Datastar::CompressionConfig do
  describe '.build' do
    it 'returns a disabled config for false' do
      config = described_class.build(false)
      expect(config.enabled?).to be(false)
    end

    it 'returns a disabled config for nil' do
      config = described_class.build(nil)
      expect(config.enabled?).to be(false)
    end

    it 'returns an enabled config with br and gzip for true' do
      config = described_class.build(true)
      expect(config.enabled?).to be(true)
    end

    it 'builds compressors from an array of symbols' do
      config = described_class.build([:gzip])
      expect(config.enabled?).to be(true)

      request = build_request('Accept-Encoding' => 'gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'builds compressors from nested array with options' do
      config = described_class.build([[:gzip, { level: 1 }]])
      expect(config.enabled?).to be(true)

      request = build_request('Accept-Encoding' => 'gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'builds mixed array of symbols and [symbol, hash] pairs' do
      config = described_class.build([[:br, { quality: 5 }], :gzip])
      expect(config.enabled?).to be(true)
    end

    it 'returns the input if already a CompressionConfig' do
      original = described_class.build(true)
      expect(described_class.build(original)).to equal(original)
    end

    it 'raises ArgumentError for invalid input' do
      expect { described_class.build('invalid') }.to raise_error(ArgumentError)
    end

    it 'raises ArgumentError for unknown compressor symbol' do
      expect { described_class.build([:deflate]) }.to raise_error(ArgumentError, /Unknown compressor/)
    end

    it 'raises LoadError at build time if brotli compressor file cannot be loaded' do
      allow(described_class).to receive(:build_compressor).and_call_original
      allow(described_class).to receive(:build_compressor).with(:br).and_raise(LoadError)
      expect { described_class.build([:br]) }.to raise_error(LoadError)
    end
  end

  describe '#negotiate' do
    it 'returns Null compressor when disabled' do
      config = described_class.build(false)
      request = build_request('Accept-Encoding' => 'br, gzip')
      compressor = config.negotiate(request)
      expect(compressor).to be_a(Datastar::Compressor::Null)
      expect(compressor.encoding).to be_nil
    end

    it 'returns Null compressor when no Accept-Encoding header' do
      config = described_class.build(true)
      request = build_request
      compressor = config.negotiate(request)
      expect(compressor).to be_a(Datastar::Compressor::Null)
    end

    it 'returns gzip compressor when client accepts gzip' do
      config = described_class.build([:gzip])
      request = build_request('Accept-Encoding' => 'gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'returns first compressor (preferred) when client supports both' do
      config = described_class.build([:br, :gzip])
      request = build_request('Accept-Encoding' => 'br, gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:br)
    end

    it 'respects list order for preference' do
      config = described_class.build([:gzip, :br])
      request = build_request('Accept-Encoding' => 'br, gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'falls back to second compressor if client does not accept first' do
      config = described_class.build([:gzip])
      request = build_request('Accept-Encoding' => 'gzip')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'returns Null when client encoding not in configured list' do
      config = described_class.build([:gzip])
      request = build_request('Accept-Encoding' => 'br')
      compressor = config.negotiate(request)
      expect(compressor).to be_a(Datastar::Compressor::Null)
    end

    it 'returns Null when Accept-Encoding has q=0 for all' do
      config = described_class.build(true)
      request = build_request('Accept-Encoding' => 'gzip;q=0, br;q=0')
      compressor = config.negotiate(request)
      expect(compressor).to be_a(Datastar::Compressor::Null)
    end

    it 'handles Accept-Encoding with quality values' do
      config = described_class.build([:gzip])
      request = build_request('Accept-Encoding' => 'gzip;q=1.0, br;q=0.5')
      compressor = config.negotiate(request)
      expect(compressor.encoding).to eq(:gzip)
    end
  end

  describe 'Compressor::NONE' do
    subject(:null) { Datastar::Compressor::NONE }

    it 'is a frozen constant' do
      expect(null).to be_frozen
      expect(null).to equal(Datastar::Compressor::NONE)
    end

    it 'returns nil encoding' do
      expect(null.encoding).to be_nil
    end

    it 'returns the socket unchanged from wrap_socket' do
      socket = Object.new
      expect(null.wrap_socket(socket)).to equal(socket)
    end

    it 'prepare_response is a no-op' do
      response = double('response')
      expect(null.prepare_response(response)).to be_nil
    end
  end

  describe 'Compressor::Gzip' do
    subject(:compressor) { Datastar::Compressor::Gzip.new({}) }

    it 'has :gzip encoding' do
      expect(compressor.encoding).to eq(:gzip)
    end

    it 'sets response headers' do
      headers = {}
      response = double('response', headers: headers)
      compressor.prepare_response(response)
      expect(headers['Content-Encoding']).to eq('gzip')
      expect(headers['Vary']).to eq('Accept-Encoding')
    end

    it 'wraps socket in Gzip::CompressedSocket' do
      socket = Object.new
      wrapped = compressor.wrap_socket(socket)
      expect(wrapped).to be_a(Datastar::Compressor::Gzip::CompressedSocket)
    end
  end

  describe 'Compressor::Brotli' do
    subject(:compressor) { Datastar::Compressor::Brotli.new({}) }

    it 'has :br encoding' do
      expect(compressor.encoding).to eq(:br)
    end

    it 'sets response headers' do
      headers = {}
      response = double('response', headers: headers)
      compressor.prepare_response(response)
      expect(headers['Content-Encoding']).to eq('br')
      expect(headers['Vary']).to eq('Accept-Encoding')
    end

    it 'wraps socket in Brotli::CompressedSocket' do
      socket = Object.new
      wrapped = compressor.wrap_socket(socket)
      expect(wrapped).to be_a(Datastar::Compressor::Brotli::CompressedSocket)
    end
  end

  private

  def build_request(headers = {})
    env = Rack::MockRequest.env_for('/', headers.transform_keys { |k| "HTTP_#{k.upcase.tr('-', '_')}" })
    Rack::Request.new(env)
  end
end
