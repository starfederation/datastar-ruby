# frozen_string_literal: true

require 'zlib'

module Datastar
  module Compressor
    # Gzip compressor — built once at config time, reused across requests.
    class Gzip
      attr_reader :encoding

      def initialize(options)
        @options = options.freeze
        @encoding = :gzip
        freeze
      end

      def prepare_response(response)
        response.headers['Content-Encoding'] = 'gzip'
        response.headers['Vary'] = 'Accept-Encoding'
      end

      def wrap_socket(socket)
        CompressedSocket.new(socket, @options)
      end

      # Gzip compressed socket using Ruby's built-in zlib.
      # Options:
      #   :level     - Compression level (0-9, default: Zlib::DEFAULT_COMPRESSION).
      #               0 = no compression, 1 = best speed, 9 = best compression.
      #               Zlib::BEST_SPEED (1) and Zlib::BEST_COMPRESSION (9) also work.
      #   :mem_level - Memory usage level (1-9, default: 8). Higher uses more memory for better compression.
      #   :strategy  - Compression strategy (default: Zlib::DEFAULT_STRATEGY).
      #               Zlib::FILTERED, Zlib::HUFFMAN_ONLY, Zlib::RLE, Zlib::FIXED are also available.
      class CompressedSocket
        def initialize(socket, options = {})
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
end
