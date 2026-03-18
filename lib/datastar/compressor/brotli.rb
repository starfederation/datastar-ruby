# frozen_string_literal: true

require 'brotli'

module Datastar
  module Compressor
    # Brotli compressor — built once at config time, reused across requests.
    # Eagerly requires the brotli gem; raises LoadError at boot if missing.
    class Brotli
      attr_reader :encoding

      def initialize(options)
        @options = options.freeze
        @encoding = :br
        freeze
      end

      def prepare_response(response)
        response.headers['Content-Encoding'] = 'br'
        response.headers['Vary'] = 'Accept-Encoding'
      end

      def wrap_socket(socket)
        CompressedSocket.new(socket, @options)
      end

      # Brotli compressed socket using the `brotli` gem.
      # Options are passed directly to Brotli::Compressor.new:
      #   :quality  - Compression quality (0-11, default: 11). Lower is faster, higher compresses better.
      #   :lgwin    - Base-2 log of the sliding window size (10-24, default: 22).
      #   :lgblock  - Base-2 log of the maximum input block size (16-24, 0 = auto, default: 0).
      #   :mode     - Compression mode (:generic, :text, or :font, default: :generic).
      #              Use :text for UTF-8 formatted text (HTML, JSON — good for SSE).
      class CompressedSocket
        def initialize(socket, options = {})
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
    end
  end
end
