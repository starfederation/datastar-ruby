module DispatcherExamples
  RSpec.shared_examples 'a dispatcher handling concurrent streams' do
    it 'spawns multiple streams in threads, triggering callbacks only once' do
      disconnects = []

      dispatcher = Datastar
                    .new(request:, response:, executor:)
                    .on_server_disconnect { |_| disconnects << true }
        .on_error { |err| puts err.backtrace.join("\n") }

      dispatcher.stream do |sse|
        sleep 0.01
        sse.patch_elements %(<div id="foo">\n<span>hello</span>\n</div>\n)
      end

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(socket.open).to be(false)
      expect(socket.lines.size).to eq(2)
      expect(socket.lines[0]).to eq("event: datastar-patch-signals\ndata: signals {\"foo\":\"bar\"}\n\n")
      expect(socket.lines[1]).to eq("event: datastar-patch-elements\ndata: elements <div id=\"foo\">\ndata: elements <span>hello</span>\ndata: elements </div>\n\n")
      expect(disconnects).to eq([true])
    end

    it 'catches exceptions raised from threads' do
      Thread.report_on_exception = false
      errs = []

      dispatcher = Datastar
                    .new(request:, response:, executor:)
                    .on_error { |err| errs << err }

      dispatcher.stream do |sse|
        sleep 0.01
        raise ArgumentError, 'Invalid argument'
      end

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(errs.first).to be_a(ArgumentError)
      Thread.report_on_exception = true
    end

    # Mutually-exclusive callback contract — matches stream_one's
    # handling_sync_errors semantics: per stream lifecycle, exactly one
    # of on_server_disconnect / on_client_disconnect / on_error fires.
    it 'does not fire on_server_disconnect when a streamer raises (multi-stream)' do
      Thread.report_on_exception = false
      events = []

      dispatcher = Datastar
                    .new(request:, response:, executor:)
                    .on_server_disconnect { |_| events << :server_disconnect }
                    .on_error { |_| events << :error }

      dispatcher.stream do |sse|
        sleep 0.01
        raise ArgumentError, 'boom'
      end

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(events).to include(:error)
      expect(events).not_to include(:server_disconnect)
      Thread.report_on_exception = true
    end

    it 'does not fire on_server_disconnect when client disconnects mid-stream (multi-stream)' do
      events = []

      dispatcher = Datastar
                    .new(request:, response:, executor:)
                    .on_server_disconnect { |_| events << :server_disconnect }
                    .on_client_disconnect { |_| events << :client_disconnect }

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end

      dispatcher.stream do |sse|
        sse.patch_signals(bar: 'baz')
      end

      # open: false → first socket.<< raises Errno::EPIPE, simulating client gone
      socket = TestSocket.new(open: false)
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(events).to include(:client_disconnect)
      expect(events).not_to include(:server_disconnect)
    end
  end
end

