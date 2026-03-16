# frozen_string_literal: true

require 'set'

module Datastar
  module Compressor
    # Null compressor — no-op, used when compression is disabled or no match.
    class Null
      def encoding = nil
      def wrap_socket(socket) = socket
      def prepare_response(_response) = nil
    end

    NONE = Null.new.freeze
  end

  # Immutable value object that holds an ordered list of pre-built compressors
  # and negotiates the best one for a given request.
  #
  # Use {.build} to create instances from user-facing configuration values.
  # The first compressor in the list is preferred when the client supports multiple.
  #
  # @example Via global configuration
  #   Datastar.configure do |config|
  #     config.compression = true                            # [:br, :gzip] with default options
  #     config.compression = [:br, :gzip]                    # preferred = first in list
  #     config.compression = [[:br, { quality: 5 }], :gzip]  # per-encoder options
  #   end
  #
  # @example Per-request negotiation (used internally by Dispatcher)
  #   compressor = Datastar.config.compression.negotiate(request)
  #   compressor.prepare_response(response)
  #   socket = compressor.wrap_socket(raw_socket)
  class CompressionConfig
    ACCEPT_ENCODING = 'HTTP_ACCEPT_ENCODING'
    BLANK_HASH = {}.freeze

    # Build a {CompressionConfig} from various user-facing input forms.
    #
    # @param input [Boolean, Array<Symbol, Array(Symbol, Hash)>, CompressionConfig]
    #   - +false+ / +nil+ — compression disabled (empty compressor list)
    #   - +true+ — enable +:br+ and +:gzip+ with default options
    #   - +Array<Symbol>+ — enable listed encodings with default options, e.g. +[:gzip]+
    #   - +Array<Array(Symbol, Hash)>+ — enable with per-encoder options,
    #     e.g. +[[:br, { quality: 5 }], :gzip]+
    #   - +CompressionConfig+ — returned as-is
    # @return [CompressionConfig]
    # @raise [ArgumentError] if +input+ is not a recognised form
    # @raise [LoadError] if a requested encoder's gem is not available (e.g. +brotli+)
    #
    # @example Disable compression
    #   CompressionConfig.build(false)
    #
    # @example Enable all supported encodings
    #   CompressionConfig.build(true)
    #
    # @example Gzip only, with custom level
    #   CompressionConfig.build([[:gzip, { level: 1 }]])
    def self.build(input)
      case input
      when CompressionConfig
        input
      when false, nil
        new([])
      when true
        new([build_compressor(:br), build_compressor(:gzip)])
      when Array
        compressors = input.map do |entry|
          case entry
          when Symbol
            build_compressor(entry)
          when Array
            name, options = entry
            build_compressor(name, options || BLANK_HASH)
          else
            raise ArgumentError, "Invalid compression entry: #{entry.inspect}. Expected Symbol or [Symbol, Hash]."
          end
        end
        new(compressors)
      else
        raise ArgumentError, "Invalid compression value: #{input.inspect}. Expected true, false, or Array."
      end
    end

    def self.build_compressor(name, options = BLANK_HASH)
      case name
      when :br
        require_relative 'compressor/brotli'
        Compressor::Brotli.new(options)
      when :gzip
        require_relative 'compressor/gzip'
        Compressor::Gzip.new(options)
      else
        raise ArgumentError, "Unknown compressor: #{name.inspect}. Expected :br or :gzip."
      end
    end
    private_class_method :build_compressor

    # @param compressors [Array<Compressor::Gzip, Compressor::Brotli>]
    #   ordered list of pre-built compressor instances. First = preferred.
    def initialize(compressors)
      @compressors = compressors.freeze
      freeze
    end

    # Whether any compressors are configured.
    #
    # @return [Boolean]
    #
    # @example
    #   CompressionConfig.build(false).enabled? # => false
    #   CompressionConfig.build(true).enabled?  # => true
    def enabled?
      @compressors.any?
    end

    # Negotiate compression with the client based on the +Accept-Encoding+ header.
    #
    # Iterates the configured compressors in order (first = preferred) and returns
    # the first one whose encoding the client accepts. Returns {Compressor::NONE}
    # when compression is disabled, the header is absent, or no match is found.
    #
    # No objects are created per-request — compressors are pre-built and reused.
    #
    # @param request [Rack::Request]
    # @return [Compressor::Gzip, Compressor::Brotli, Compressor::Null]
    #
    # @example
    #   config = CompressionConfig.build([:gzip, :br])
    #   compressor = config.negotiate(request)
    #   compressor.prepare_response(response)
    #   socket = compressor.wrap_socket(raw_socket)
    def negotiate(request)
      return Compressor::NONE unless enabled?

      accepted = parse_accept_encoding(request.get_header(ACCEPT_ENCODING).to_s)
      return Compressor::NONE if accepted.empty?

      @compressors.each do |compressor|
        return compressor if accepted.include?(compressor.encoding)
      end

      Compressor::NONE
    end

    private

    # Parse Accept-Encoding header into a set of encoding symbols
    # @param header [String]
    # @return [Set<Symbol>]
    def parse_accept_encoding(header)
      return Set.new if header.empty?

      encodings = Set.new
      header.split(',').each do |part|
        encoding, quality = part.strip.split(';', 2)
        encoding = encoding.strip.downcase
        if quality
          q_val = quality.strip.match(/q=(\d+\.?\d*)/)
          next if q_val && q_val[1].to_f == 0
        end
        encodings << encoding.to_sym
      end
      encodings
    end
  end
end
