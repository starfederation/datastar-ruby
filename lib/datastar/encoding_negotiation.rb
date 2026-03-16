# frozen_string_literal: true

module Datastar
  module EncodingNegotiation
    ACCEPT_ENCODING = 'HTTP_ACCEPT_ENCODING'

    # Negotiate compression encoding based on request headers and configuration.
    #
    # @param request [Rack::Request]
    # @param preferred [Symbol] preferred encoding (:br or :gzip)
    # @param enabled [Boolean, Array<Symbol>] compression config
    # @return [Symbol, nil] :br, :gzip, or nil
    def self.negotiate(request, preferred:, enabled:)
      return nil unless enabled

      accepted = parse_accept_encoding(request.get_header(ACCEPT_ENCODING).to_s)
      return nil if accepted.empty?

      available = if enabled == true
                    %i[br gzip]
                  else
                    Array(enabled)
                  end

      # Try preferred encoding first
      if available.include?(preferred) && accepted.include?(preferred)
        return preferred if encoding_available?(preferred)
      end

      # Fall back to other available encodings
      (available - [preferred]).each do |enc|
        return enc if accepted.include?(enc) && encoding_available?(enc)
      end

      nil
    end

    # Check if the encoding implementation is available
    # @param encoding [Symbol]
    # @return [Boolean]
    def self.encoding_available?(encoding)
      case encoding
      when :br
        brotli_available?
      when :gzip
        true # zlib is part of Ruby stdlib
      else
        false
      end
    end

    # Check if the brotli gem is installed (memoized)
    # @return [Boolean]
    def self.brotli_available?
      return @brotli_available if defined?(@brotli_available)

      @brotli_available = begin
        require 'brotli'
        true
      rescue LoadError
        false
      end
    end

    # Reset memoized brotli availability (for testing)
    def self.reset_brotli_cache!
      remove_instance_variable(:@brotli_available) if defined?(@brotli_available)
    end

    # Parse Accept-Encoding header into a set of encoding symbols
    # @param header [String]
    # @return [Set<Symbol>]
    def self.parse_accept_encoding(header)
      return Set.new if header.empty?

      encodings = Set.new
      header.split(',').each do |part|
        encoding, quality = part.strip.split(';', 2)
        encoding = encoding.strip.downcase
        # Skip if quality is explicitly 0
        if quality
          q_val = quality.strip.match(/q=(\d+\.?\d*)/)
          next if q_val && q_val[1].to_f == 0
        end
        encodings << encoding.to_sym
      end
      encodings
    end

    private_class_method :parse_accept_encoding
  end
end
