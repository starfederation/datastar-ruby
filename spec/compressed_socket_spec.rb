# frozen_string_literal: true

require 'datastar'
require 'datastar/compressor/gzip'
require 'datastar/compressor/brotli'

RSpec.describe 'Compressor compressed sockets' do
  let(:raw_socket) { StringSocket.new }
  let(:sse_data) { "event: datastar-patch-signals\ndata: signals {\"foo\":\"bar\"}\n\n" }

  # A simple socket that collects binary data
  class StringSocket
    attr_reader :closed

    def initialize
      @buffer = String.new(encoding: Encoding::BINARY)
      @closed = false
    end

    def <<(data)
      @buffer << data.b
      self
    end

    def close
      @closed = true
    end

    def bytes
      @buffer
    end
  end

  describe Datastar::Compressor::Gzip::CompressedSocket do
    subject(:socket) { described_class.new(raw_socket) }

    it 'compresses data and decompresses to original' do
      socket << sse_data
      socket.close

      decompressed = Zlib::Inflate.new(31).inflate(raw_socket.bytes)
      expect(decompressed).to eq(sse_data)
    end

    it 'flushes data after each write (data available before close)' do
      socket << sse_data
      # Data should be in raw_socket before close
      expect(raw_socket.bytes).not_to be_empty

      partial = Zlib::Inflate.new(31).inflate(raw_socket.bytes)
      expect(partial).to eq(sse_data)
    end

    it 'handles multiple writes' do
      data1 = "event: datastar-patch-signals\ndata: signals {\"a\":1}\n\n"
      data2 = "event: datastar-patch-signals\ndata: signals {\"b\":2}\n\n"

      socket << data1
      socket << data2
      socket.close

      decompressed = Zlib::Inflate.new(31).inflate(raw_socket.bytes)
      expect(decompressed).to eq(data1 + data2)
    end

    it 'closes the underlying socket' do
      socket << sse_data
      socket.close
      expect(raw_socket.closed).to be(true)
    end

    it 'accepts compression level option' do
      socket = described_class.new(raw_socket, level: Zlib::BEST_SPEED)
      socket << sse_data
      socket.close

      decompressed = Zlib::Inflate.new(31).inflate(raw_socket.bytes)
      expect(decompressed).to eq(sse_data)
    end
  end

  describe Datastar::Compressor::Brotli::CompressedSocket do
    subject(:socket) { described_class.new(raw_socket) }

    it 'compresses data and decompresses to original' do
      socket << sse_data
      socket.close

      decompressed = ::Brotli.inflate(raw_socket.bytes)
      expect(decompressed).to eq(sse_data)
    end

    it 'flushes data after each write (data available before close)' do
      socket << sse_data
      expect(raw_socket.bytes).not_to be_empty
    end

    it 'handles multiple writes' do
      data1 = "event: datastar-patch-signals\ndata: signals {\"a\":1}\n\n"
      data2 = "event: datastar-patch-signals\ndata: signals {\"b\":2}\n\n"

      socket << data1
      socket << data2
      socket.close

      decompressed = ::Brotli.inflate(raw_socket.bytes)
      expect(decompressed).to eq(data1 + data2)
    end

    it 'closes the underlying socket' do
      socket << sse_data
      socket.close
      expect(raw_socket.closed).to be(true)
    end
  end

end
