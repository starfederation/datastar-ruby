#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark: SSE compression payload sizes
#
# Compares bytes-over-the-wire for no compression, gzip, and brotli
# when streaming large HTML elements via Datastar's SSE protocol.
#
# Usage:
#   bundle exec ruby benchmarks/compression.rb
#
# The benchmark patches realistic HTML payloads of increasing size
# through the full Datastar SSE pipeline (ServerSentEventGenerator →
# CompressedSocket → raw socket) and reports the resulting byte sizes
# and compression ratios.

require 'bundler/setup'
require 'datastar'
require 'datastar/compressor/gzip'
require 'datastar/compressor/brotli'

# --- Payload generators ---------------------------------------------------

# A user-row partial, repeated N times inside a <tbody>.
# Realistic: IDs, data attributes, mixed text, Tailwind-style classes.
def html_table(row_count)
  rows = row_count.times.map do |i|
    <<~HTML
      <tr id="user-row-#{i}" class="border-b border-gray-200 hover:bg-gray-50 transition-colors duration-150" data-user-id="#{i}" data-signal-selected="false">
        <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">#{i + 1}</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">user-#{i}@example.com</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">#{%w[Admin Editor Viewer].sample}</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">2025-01-#{(i % 28 + 1).to_s.rjust(2, '0')}</td>
        <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
          <button class="text-indigo-600 hover:text-indigo-900 mr-3" data-on-click="$$put('/users/#{i}/edit')">Edit</button>
          <button class="text-red-600 hover:text-red-900" data-on-click="$$delete('/users/#{i}')">Delete</button>
        </td>
      </tr>
    HTML
  end

  <<~HTML
    <tbody id="users-table-body">
    #{rows.join}
    </tbody>
  HTML
end

# A dashboard card with nested elements — charts placeholder, stats, lists.
def html_dashboard(card_count)
  cards = card_count.times.map do |i|
    <<~HTML
      <div id="card-#{i}" class="bg-white overflow-hidden shadow-lg rounded-2xl border border-gray-100 p-6 flex flex-col gap-4">
        <div class="flex items-center justify-between">
          <h3 class="text-lg font-semibold text-gray-900">Metric #{i + 1}</h3>
          <span class="inline-flex items-center rounded-full bg-green-50 px-2 py-1 text-xs font-medium text-green-700 ring-1 ring-inset ring-green-600/20">+#{rand(1..99)}%</span>
        </div>
        <div class="text-3xl font-bold text-gray-900">#{rand(1_000..99_999).to_s.chars.each_slice(3).map(&:join).join(',')}</div>
        <div class="h-32 bg-gradient-to-r from-indigo-50 to-indigo-100 rounded-lg flex items-end gap-1 p-2">
          #{8.times.map { |j| "<div class=\"bg-indigo-#{[400, 500, 600].sample} rounded-t w-full\" style=\"height: #{rand(20..100)}%\"></div>" }.join("\n          ")}
        </div>
        <ul class="divide-y divide-gray-100">
          #{5.times.map { |j| "<li class=\"flex justify-between py-2 text-sm\"><span class=\"text-gray-500\">Region #{j + 1}</span><span class=\"font-medium text-gray-900\">#{rand(100..9_999)}</span></li>" }.join("\n          ")}
        </ul>
      </div>
    HTML
  end

  <<~HTML
    <div id="dashboard-grid" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6 p-6">
    #{cards.join}
    </div>
  HTML
end

# --- Socket that counts bytes --------------------------------------------

class ByteCountingSocket
  attr_reader :total_bytes

  def initialize
    @total_bytes = 0
  end

  def <<(data)
    @total_bytes += data.bytesize
    self
  end

  def close; end
end

# --- Helpers --------------------------------------------------------------

# Pipe an HTML payload through the full SSE + compression stack
# and return the byte count that would go over the wire.
def measure_bytes(html, encoding)
  socket = ByteCountingSocket.new

  wrapped = case encoding
            when :none  then socket
            when :gzip  then Datastar::Compressor::Gzip::CompressedSocket.new(socket)
            when :br    then Datastar::Compressor::Brotli::CompressedSocket.new(socket, mode: :text)
            end

  generator = Datastar::ServerSentEventGenerator.new(
    wrapped,
    signals: {},
    view_context: nil
  )

  generator.patch_elements(html)
  wrapped.close unless encoding == :none

  socket.total_bytes
end

def format_bytes(bytes)
  if bytes >= 1024 * 1024
    "%.1f MB" % (bytes / (1024.0 * 1024))
  elsif bytes >= 1024
    "%.1f KB" % (bytes / 1024.0)
  else
    "#{bytes} B"
  end
end

def ratio(original, compressed)
  "%.1f%%" % ((1.0 - compressed.to_f / original) * 100)
end

# --- Run benchmarks -------------------------------------------------------

SCENARIOS = [
  ["Table 10 rows",     -> { html_table(10) }],
  ["Table 50 rows",     -> { html_table(50) }],
  ["Table 200 rows",    -> { html_table(200) }],
  ["Table 1000 rows",   -> { html_table(1000) }],
  ["Dashboard 5 cards", -> { html_dashboard(5) }],
  ["Dashboard 20 cards",-> { html_dashboard(20) }],
  ["Dashboard 50 cards",-> { html_dashboard(50) }],
]

ENCODINGS = %i[none gzip br]

# Header
puts "Datastar SSE Compression Benchmark"
puts "=" * 90
puts
puts format(
  "%-22s %12s %12s %8s %12s %8s",
  "Scenario", "No Compress", "Gzip", "Saved", "Brotli", "Saved"
)
puts "-" * 90

SCENARIOS.each do |name, generator|
  html = generator.call
  results = ENCODINGS.map { |enc| [enc, measure_bytes(html, enc)] }.to_h
  none = results[:none]

  puts format(
    "%-22s %12s %12s %8s %12s %8s",
    name,
    format_bytes(none),
    format_bytes(results[:gzip]),
    ratio(none, results[:gzip]),
    format_bytes(results[:br]),
    ratio(none, results[:br])
  )
end

# --- Streaming: multiple SSE events over one connection -------------------

# Simulates a long-lived SSE connection where rows are patched individually
# (e.g. a live-updating table). The compressor stays open across events,
# so repeated structure (CSS classes, attribute patterns) compresses
# increasingly well as the dictionary builds up.

def measure_streaming_bytes(payloads, encoding)
  socket = ByteCountingSocket.new

  wrapped = case encoding
            when :none  then socket
            when :gzip  then Datastar::Compressor::Gzip::CompressedSocket.new(socket)
            when :br    then Datastar::Compressor::Brotli::CompressedSocket.new(socket, mode: :text)
            end

  generator = Datastar::ServerSentEventGenerator.new(
    wrapped,
    signals: {},
    view_context: nil
  )

  payloads.each { |html| generator.patch_elements(html) }
  wrapped.close unless encoding == :none

  socket.total_bytes
end

def table_rows(count)
  count.times.map do |i|
    <<~HTML
      <tr id="user-row-#{i}" class="border-b border-gray-200 hover:bg-gray-50 transition-colors duration-150" data-user-id="#{i}" data-signal-selected="false">
        <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-gray-900">#{i + 1}</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">user-#{i}@example.com</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">#{%w[Admin Editor Viewer].sample}</td>
        <td class="px-6 py-4 whitespace-nowrap text-sm text-gray-500">2025-01-#{(i % 28 + 1).to_s.rjust(2, '0')}</td>
        <td class="px-6 py-4 whitespace-nowrap text-right text-sm font-medium">
          <button class="text-indigo-600 hover:text-indigo-900 mr-3" data-on-click="$$put('/users/#{i}/edit')">Edit</button>
          <button class="text-red-600 hover:text-red-900" data-on-click="$$delete('/users/#{i}')">Delete</button>
        </td>
      </tr>
    HTML
  end
end

puts
puts
puts "Streaming: individual row patches over one SSE connection"
puts "=" * 90
puts
puts format(
  "%-22s %12s %12s %8s %12s %8s",
  "Scenario", "No Compress", "Gzip", "Saved", "Brotli", "Saved"
)
puts "-" * 90

[10, 50, 200, 1000].each do |count|
  payloads = table_rows(count)
  results = ENCODINGS.map { |enc| [enc, measure_streaming_bytes(payloads, enc)] }.to_h
  none = results[:none]

  puts format(
    "%-22s %12s %12s %8s %12s %8s",
    "#{count} row patches",
    format_bytes(none),
    format_bytes(results[:gzip]),
    ratio(none, results[:gzip]),
    format_bytes(results[:br]),
    ratio(none, results[:br])
  )
end

puts
puts "Notes:"
puts "  - Single-event sizes include full SSE framing (event: / data: prefixes)"
puts "  - Gzip: default compression level, gzip framing (window_bits=31)"
puts "  - Brotli: default quality (11) with mode: :text"
puts "  - Streaming rows: each row is a separate patch_elements SSE event"
puts "    over one persistent compressed connection. The compressor dictionary"
puts "    builds up across events, improving ratios for repetitive markup."
