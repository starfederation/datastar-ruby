# frozen_string_literal: true

module Datastar
  # Decorator that wraps a socket and compresses data before writing.
  # Supports Brotli and gzip compression.
  # Used internally by Dispatcher when compression is negotiated.
  module CompressedSocket
    # Brotli compression using the `brotli` gem.
    # Options are passed directly to Brotli::Compressor.new:
    #   :quality  - Compression quality (0-11, default: 11). Lower is faster, higher compresses better.
    #   :lgwin    - Base-2 log of the sliding window size (10-24, default: 22).
    #   :lgblock  - Base-2 log of the maximum input block size (16-24, 0 = auto, default: 0).
    #   :mode     - Compression mode (:generic, :text, or :font, default: :generic).
    #              Use :text for UTF-8 formatted text (HTML, JSON — good for SSE).
    class Brotli
      def initialize(socket, options = {})
        require 'brotli'
        @socket = socket
        @compressor = ::Brotli::Compressor.new(options)
      end

      def <<(data)
        compressed = @compressor.process(data)
        @socket << compressed if compressed && !compressed.empty?
        flushed = @compressor.flush
        @socket << flushed if flushed && !flushed.empty?
        self
      end

      def close
        final = @compressor.finish
        @socket << final if final && !final.empty?
        @socket.close
      end
    end

    # Gzip compression using Ruby's built-in zlib.
    # Options:
    #   :level     - Compression level (0-9, default: Zlib::DEFAULT_COMPRESSION).
    #               0 = no compression, 1 = best speed, 9 = best compression.
    #               Zlib::BEST_SPEED (1) and Zlib::BEST_COMPRESSION (9) are also available.
    #   :mem_level - Memory usage level (1-9, default: 8). Higher uses more memory for better compression.
    #   :strategy  - Compression strategy (default: Zlib::DEFAULT_STRATEGY).
    #               Zlib::FILTERED, Zlib::HUFFMAN_ONLY, Zlib::RLE, Zlib::FIXED are also available.
    class Gzip
      def initialize(socket, options = {})
        require 'zlib'
        level = options.fetch(:level, Zlib::DEFAULT_COMPRESSION)
        mem_level = options.fetch(:mem_level, Zlib::DEF_MEM_LEVEL)
        strategy = options.fetch(:strategy, Zlib::DEFAULT_STRATEGY)
        # Use raw deflate with gzip wrapping (window_bits 31 = 15 + 16)
        @socket = socket
        @deflate = Zlib::Deflate.new(level, 31, mem_level, strategy)
      end

      def <<(data)
        compressed = @deflate.deflate(data, Zlib::SYNC_FLUSH)
        @socket << compressed if compressed && !compressed.empty?
        self
      end

      def close
        final = @deflate.finish
        @socket << final if final && !final.empty?
        @socket.close
      ensure
        @deflate.close
      end
    end
  end
end
