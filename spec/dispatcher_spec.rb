# frozen_string_literal: true

class TestSocket
  attr_reader :lines, :open

  def initialize(open: true)
    @lines = []
    @open = open
    @finish = Thread::Queue.new
  end

  def <<(line)
    raise Errno::EPIPE, 'Socket closed' unless @open

    @lines << line
  end

  def close 
    @open = false
    @finish << true
  end

  def split_lines
    @lines.join.split("\n")
  end

  # Streams run in threads
  # we can call this to signal the end of the stream
  # in tests
  def wait_for_close(&)
    @finish.pop
    yield if block_given?
  end
end

RSpec.describe Datastar::Dispatcher do
  include DispatcherExamples

  subject(:dispatcher) { Datastar.new(request:, response:, view_context:) }

  let(:request) { build_request('/events') }
  let(:response) { Rack::Response.new(nil, 200) }
  let(:view_context) { double('View context') }

  describe '#initialize' do
    it 'sets Content-Type to text/event-stream' do
      expect(dispatcher.response['Content-Type']).to eq('text/event-stream')
    end

    it 'sets Cache-Control to no-cache' do
      expect(dispatcher.response['Cache-Control']).to eq('no-cache')
    end

    it 'sets Connection to keep-alive' do
      expect(dispatcher.response['Connection']).to eq('keep-alive')
    end

    it 'sets X-Accel-Buffering: no for NGinx and other proxies' do
      expect(dispatcher.response['X-Accel-Buffering']).to eq('no')
    end

    it 'does not set Connection header if not HTTP/1.1' do
      request.env['SERVER_PROTOCOL'] = 'HTTP/2.0'
      expect(dispatcher.response['Connection']).to be_nil
    end

    it 'wraps the request in a new Rack::Request with a duplicated env' do
      expect(dispatcher.request).not_to equal(request)
      expect(dispatcher.request.env).not_to equal(request.env)
    end

    it 'isolates the dispatcher from later env mutations by upstream middleware' do
      request.env['PATH_INFO'] = '/events'
      request.env['SCRIPT_NAME'] = '/app'
      dispatcher = Datastar.new(request:, response:, view_context:)

      # Simulate middleware such as Rack::URLMap restoring SCRIPT_NAME/PATH_INFO
      # in an ensure block after the handler returns but while async stream
      # fibers are still running.
      request.env['PATH_INFO'] = '/'
      request.env['SCRIPT_NAME'] = ''

      expect(dispatcher.request.path_info).to eq('/events')
      expect(dispatcher.request.script_name).to eq('/app')
    end
  end

  specify '.from_rack_env' do
    dispatcher = Datastar.from_rack_env(request.env)

    expect(dispatcher.response['Content-Type']).to eq('text/event-stream')
    expect(dispatcher.response['Cache-Control']).to eq('no-cache')
    expect(dispatcher.response['Connection']).to eq('keep-alive')
  end

  specify '#sse?' do
    expect(dispatcher.sse?).to be(true)

    request = build_request('/events', headers: { 'HTTP_ACCEPT' => 'application/json' })
    dispatcher = Datastar.new(request:, response:, view_context:)
    expect(dispatcher.sse?).to be(false)

    request = build_request('/events', headers: { 'HTTP_ACCEPT' => 'text/event-stream,application/json' })
    dispatcher = Datastar.new(request:, response:, view_context:)
    expect(dispatcher.sse?).to be(true)
  end

  describe '#patch_elements' do
    it 'produces a streameable response body with D* elements' do
      dispatcher.patch_elements %(<div id="foo">\n<span>hello</span>\n</div>\n)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq(["event: datastar-patch-elements\ndata: elements <div id=\"foo\">\ndata: elements <span>hello</span>\ndata: elements </div>\n\n"])
    end

    it 'takes D* options' do
      dispatcher.patch_elements(
        %(<div id="foo">\n<span>hello</span>\n</div>),
        id: 72,
        retry_duration: 2000,
        use_view_transition: true,
      )
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\nid: 72\nretry: 2000\ndata: useViewTransition true\ndata: elements <div id="foo">\ndata: elements <span>hello</span>\ndata: elements </div>\n\n)])
    end

    it 'omits retry if using default value' do
      dispatcher.patch_elements(
        %(<div id="foo">\n<span>hello</span>\n</div>\n),
        id: 72,
        retry_duration: 1000
      )
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\nid: 72\ndata: elements <div id="foo">\ndata: elements <span>hello</span>\ndata: elements </div>\n\n)])
    end

    it 'works with #call(view_context:) interfaces' do
      template_class = Class.new do
        def self.call(context:) = %(<div id="foo">\n<span>#{context}</span>\n</div>\n)
      end

      dispatcher.patch_elements(
        template_class,
        id: 72,
        retry_duration: 2000
      )
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.split_lines).to eq([
        %(event: datastar-patch-elements),
        %(id: 72),
        %(retry: 2000),
        %(data: elements <div id="foo">),
        %(data: elements <span>#[Double "View context"]</span>),
        %(data: elements </div>)
      ])
    end

    require 'phlex'
    it 'works with Phlex components' do
      component_class = Class.new(Phlex::HTML) do
        def view_template
          h1(id: 'foo') { 'Hello, ' + context.to_s }
        end
      end

      dispatcher.patch_elements(component_class.new)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.split_lines).to eq([
        %(event: datastar-patch-elements),
        %(data: elements <h1 id="foo">Hello, #[Double &quot;View context&quot;]</h1>)
      ])
    end

    it 'works with #render_in(view_context, &) interfaces' do
      template_class = Class.new do
        def self.render_in(view_context) = %(<div id="foo">\n<span>#{view_context}</span>\n</div>\n)
      end

      dispatcher.patch_elements(
        template_class,
        id: 72,
        retry_duration: 2000
      )
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\nid: 72\nretry: 2000\ndata: elements <div id="foo">\ndata: elements <span>#{view_context}</span>\ndata: elements </div>\n\n)])
    end

    it 'accepts an array of elements' do
      dispatcher.patch_elements([
        %(<div id="foo">Hello</div>),
        %(<div id="bar">Bye</div>)
      ])
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq(["event: datastar-patch-elements\ndata: elements <div id=\"foo\">Hello</div>\ndata: elements <div id=\"bar\">Bye</div>\n\n"])
    end
  end

  describe '#remove_elements' do
    it 'produces D* patch elements with "remove" mode' do
      dispatcher.remove_elements('#list-item-1')
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\ndata: mode remove\ndata: selector #list-item-1\n\n)])
    end

    it 'takes D* options' do
      dispatcher.remove_elements('#list-item-1', id: 72)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\nid: 72\ndata: mode remove\ndata: selector #list-item-1\n\n)])
    end

    it 'takes an array of selectors' do
      dispatcher.remove_elements(%w[#item1 #item2])
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\ndata: mode remove\ndata: selector #item1, #item2\n\n)])
    end
  end

  describe '#patch_signals' do
    it 'produces a streameable response body with D* signals' do
      dispatcher.patch_signals %({ "foo": "bar" })
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-signals\ndata: signals { "foo": "bar" }\n\n)])
    end

    it 'takes a Hash of signals' do
      dispatcher.patch_signals(foo: 'bar')
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-signals\ndata: signals {"foo":"bar"}\n\n)])
    end

    it 'takes D* options' do
      dispatcher.patch_signals({foo: 'bar'}, event_id: 72, retry_duration: 2000, only_if_missing: true)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-signals\nid: 72\nretry: 2000\ndata: onlyIfMissing true\ndata: signals {"foo":"bar"}\n\n)])
    end

    it 'takes a (JSON encoded) string as signals' do
      signals = <<~JSON
      {
        "foo": "bar",
        "age": 42
      }
      JSON
      dispatcher.patch_signals(signals)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.split_lines).to eq([
        %(event: datastar-patch-signals),
        %(data: signals {),
        %(data: signals   "foo": "bar",),
        %(data: signals   "age": 42),
        %(data: signals }),
      ])
    end
  end

  describe '#remove_signals' do
    it 'sets signal values to null via #patch_signals' do
      dispatcher.remove_signals ['user.name', 'user.email']
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-signals\ndata: signals {"user":{"name":null,"email":null}}\n\n)])
    end

    it 'takes D* options' do
      dispatcher.remove_signals 'user.name', event_id: 72, retry_duration: 2000
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-signals\nid: 72\nretry: 2000\ndata: signals {"user":{"name":null}}\n\n)])
    end
  end

  describe '#execute_script' do
    it 'appends a <script> tag via patch-elements' do
      dispatcher.execute_script %(alert('hello'))
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\ndata: selector body\ndata: mode append\ndata: elements <script data-effect="el.remove()">alert('hello')</script>\n\n)])
    end

    it 'takes D* options' do
      dispatcher.execute_script %(alert('hello')), event_id: 72, auto_remove: false
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\nid: 72\ndata: selector body\ndata: mode append\ndata: elements <script>alert('hello')</script>\n\n)])
    end

    it 'takes attributes Hash' do
      dispatcher.execute_script %(alert('hello')), attributes: { type: 'text/javascript', title: 'alert' }
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\ndata: selector body\ndata: mode append\ndata: elements <script type="text/javascript" title="alert" data-effect="el.remove()">alert('hello')</script>\n\n)])
    end

    it 'accepts camelized string options' do
      dispatcher.execute_script(
        %(console.log('hello');),
        'eventId' => 'event1',
        'retryDuration' => 2000,
        'attributes' => {
          'type' => 'text/javascript',
          'blocking' => false
        },
        'autoRemove' => false
      )
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.split_lines).to eq([
        %(event: datastar-patch-elements),
        %(id: event1),
        %(retry: 2000),
        %(data: selector body),
        %(data: mode append),
        %(data: elements <script type="text/javascript" blocking="false">console.log('hello');</script>)
      ])
    end
  end

  describe '#redirect' do
    it 'sends an execute_script event with a window.location change' do
      dispatcher.redirect '/guide'
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(socket.open).to be(false)
      expect(socket.lines).to eq([%(event: datastar-patch-elements\ndata: selector body\ndata: mode append\ndata: elements <script data-effect="el.remove()">setTimeout(() => { window.location = "\\/guide" })</script>\n\n)])
    end

    it 'wraps single quotes inside a double-quoted JS string literal so they cannot break out' do
      # Pre-fix: window.location = '/foo'); alert(1); ('';
      #   → the ' in the URL closed the JS string and ); alert(1); ( ran as JS (XSS).
      # Post-fix: window.location = "/foo'); alert(1); ('"
      #   → JSON.generate emits a double-quoted literal; ' has no special meaning
      #     inside ", so the breakout payload is harmless content of the URL value.
      dispatcher.redirect("/foo'); alert(1); ('")
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      # The breakout payload appears as inert string content of the URL
      # (leading / is escape_slashed to \/, harmless in JS)
      expect(output).to include(%[window.location = "\\/foo'); alert(1); ('"])
      # The wrapping <script>…</script> stays balanced — no premature close
      expect(output.scan('<script').size).to eq(1)
      expect(output.scan('</script>').size).to eq(1)
    end

    it 'JS-escapes double quotes in URL' do
      dispatcher.redirect('/foo"); alert(1); ("')
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      expect(output).not_to include('"); alert(1); ("')
      expect(output).to include('\\"')
    end

    it 'JS-escapes backslashes in URL' do
      dispatcher.redirect('/foo\\"); alert(1); //')
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      # The literal sequence "); from the payload must not appear unescaped
      expect(output).not_to include('"); alert(1); //')
    end

    it 'escapes </script> so it cannot prematurely close the surrounding <script> tag' do
      dispatcher.redirect('/foo</script><script>alert(1)</script>')
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      # The wrapping <script>...</script> stays intact: only one closing tag,
      # at the very end. The injected </script><script>alert(1)</script>
      # becomes <\/script><script>alert(1)<\/script> inside the JS string.
      expect(output).not_to match(%r{</script><script>alert\(1\)})
      expect(output.scan('</script>').size).to eq(1)
    end

    it 'escapes U+2028 line separator (a JS string-literal terminator)' do
      dispatcher.redirect("/foo bar")
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      # Must be escaped to   so the JS string literal stays intact
      expect(output).to include('\\u2028')
      expect(output).not_to include(" ")
    end

    it 'escapes U+2029 paragraph separator (also a JS string-literal terminator)' do
      dispatcher.redirect("/foo bar")
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      output = socket.lines.join

      expect(output).to include('\\u2029')
      expect(output).not_to include(" ")
    end
  end

  describe '#signals' do
    context 'with POST request' do
      specify 'Rails parsed parameters' do
        request = build_request(
          '/events', 
          method: 'POST', 
          headers: { 
            'action_dispatch.request.request_parameters' => { 'event' => { 'foo' => 'bar' } }
          }
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq({ 'foo' => 'bar' })
      end

      specify 'no signals in Rails parameters' do
        request = build_request(
          '/events', 
          method: 'POST', 
          headers: { 
            'action_dispatch.request.request_parameters' => {}
          }
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq({})
      end

      specify 'JSON request with signals in body' do
        request = build_request(
          '/events', 
          method: 'POST', 
          content_type: 'application/json',
          body: %({ "foo": "bar" })
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq({ 'foo' => 'bar' })
      end

      specify 'multipart form request' do
        request = build_request(
          '/events', 
          method: 'POST', 
          content_type: 'multipart/form-data',
          body: 'user[name]=joe&user[email]=joe@email.com'
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq('user' => { 'name' => 'joe', 'email' => 'joe@email.com' })
      end
    end

    context 'with GET request' do
      specify 'with signals in ?datastar=[JSON signals]' do
        query = %({"foo":"bar"})
        request = build_request(
          %(/events?datastar=#{URI.encode_uri_component(query)}), 
          method: 'GET', 
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq('foo' => 'bar')
      end

      specify 'with no signals' do
        request = build_request(
          %(/events), 
          method: 'GET', 
        )

        dispatcher = Datastar.new(request:, response:)
        expect(dispatcher.signals).to eq({})
      end
    end
  end

  describe '#stream' do
    it 'writes multiple events to socket' do
      socket = TestSocket.new
      dispatcher.on_error do |ex|
        raise ex
      end
      dispatcher.stream do |sse|
        sse.patch_elements %(<div id="foo">\n<span>hello</span>\n</div>)
        sse.patch_signals(foo: 'bar')
      end

      dispatcher.response.body.call(socket)

      socket.wait_for_close
      expect(socket.open).to be(false)
      expect(socket.lines.size).to eq(2)
      expect(socket.lines[0]).to eq("event: datastar-patch-elements\ndata: elements <div id=\"foo\">\ndata: elements <span>hello</span>\ndata: elements </div>\n\n")
      expect(socket.lines[1]).to eq("event: datastar-patch-signals\ndata: signals {\"foo\":\"bar\"}\n\n")
    end

    it 'returns a Rack array response' do
      status, headers, _body = dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      expect(status).to eq(200)
      expect(headers['content-type']).to eq('text/event-stream')
      expect(headers['cache-control']).to eq('no-cache')
      expect(headers['connection']).to eq('keep-alive')
    end

    context 'with multiple streams' do
      let(:executor) { Datastar.config.executor }

      describe 'default thread-based executor' do
        it_behaves_like 'a dispatcher handling concurrent streams'
      end

      describe 'Async-based executor' do
        around do |example|
          Sync do
            example.run
          end
        end

        let(:executor) { Datastar::AsyncExecutor.new }
        it_behaves_like 'a dispatcher handling concurrent streams'
      end
    end

    specify ':heartbeat enabled' do
      dispatcher = Datastar.new(request:, response:, heartbeat: 0.001)
      connected = true
      block_called = false
      dispatcher.on_client_disconnect { |conn| connected = false }

      socket = TestSocket.new(open: false)
      # allow(socket).to receive(:<<).with("\n").and_raise(Errno::EPIPE, 'Socket closed')

      dispatcher.stream do |sse|
        sleep 10
        block_called = true
      end

      dispatcher.response.body.call(socket)
      socket.wait_for_close

      expect(connected).to be(false)
      expect(block_called).to be(false)
    end

    specify ':heartbeat disabled' do
      dispatcher = Datastar.new(request:, response:, heartbeat: false)
      connected = true
      block_called = false
      dispatcher.on_client_disconnect { |conn| connected = false }

      socket = TestSocket.new(open: false)

      dispatcher.stream do |sse|
        sleep 0.001
        block_called = true
      end

      dispatcher.response.body.call(socket)
      expect(connected).to be(true)
      expect(block_called).to be(true)
    end

    specify '#stream with per-call heartbeat: false overrides constructor heartbeat' do
      dispatcher = Datastar.new(request:, response:, heartbeat: 0.001)
      connected = true
      block_called = false
      dispatcher.on_client_disconnect { |conn| connected = false }

      socket = TestSocket.new(open: false)

      dispatcher.stream(heartbeat: false) do |sse|
        sleep 0.001
        block_called = true
      end

      dispatcher.response.body.call(socket)
      expect(connected).to be(true)
      expect(block_called).to be(true)
    end

    specify '#stream restores heartbeat state after a per-call override' do
      dispatcher = Datastar.new(request:, response:, heartbeat: 0.001)

      dispatcher.stream(heartbeat: false) { |sse| }
      expect(dispatcher.heartbeat).to eq(0.001)
    end

    specify '#signals' do
      request = build_request(
        %(/events), 
        method: 'POST', 
        content_type: 'multipart/form-data',
        body: 'user[name]=joe&user[email]=joe@email.com'
      )

      dispatcher = Datastar.new(request:, response:)
      signals = nil

      dispatcher.stream do |sse|
        signals = sse.signals
      end
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.wait_for_close

      expect(signals['user']['name']).to eq('joe')
    end

    specify '#on_connect' do
      connected = false
      dispatcher.on_connect { |conn| connected = true }
      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      expect(connected).to be(true)
    end

    specify '#on_client_disconnect' do
      events = []
      dispatcher
        .on_connect { |conn| events << true }
        .on_client_disconnect { |conn| events << false }

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      socket = TestSocket.new(open: false)
      
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(events).to eq([true, false])
    end

    specify '#check_connection triggers #on_client_disconnect' do
      events = []
      dispatcher
        .on_connect { |conn| events << true }
        .on_client_disconnect { |conn| events << false }

      dispatcher.stream do |sse|
        sse.check_connection!
      end
      socket = TestSocket.new(open: false)
      
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(events).to eq([true, false])
    end

    specify '#on_server_disconnect' do
      events = []
      dispatcher
        .on_connect { |conn| events << true }
        .on_server_disconnect { |conn| events << false }

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      socket = TestSocket.new
      
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(events).to eq([true, false])
    end

    specify '#on_error' do
      allow(Datastar.config.logger).to receive(:error)
      errors = []
      dispatcher.on_error { |ex| errors << ex }

      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      socket = TestSocket.new
      allow(socket).to receive(:<<).and_raise(ArgumentError, 'Invalid argument')
      
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(errors.first).to be_a(ArgumentError)
      expect(Datastar.config.logger).to have_received(:error).with(/ArgumentError \(Invalid argument\):/)
    end

    specify 'with global on_error' do
      errs = []
      Datastar.config.on_error { |ex| errs << ex }
      socket = TestSocket.new
      allow(socket).to receive(:<<).and_raise(ArgumentError, 'Invalid argument')
      
      dispatcher.stream do |sse|
        sse.patch_signals(foo: 'bar')
      end
      dispatcher.response.body.call(socket)
      socket.wait_for_close
      expect(errs.first).to be_a(ArgumentError)
    end
  end

  describe 'compression' do
    it 'sets Content-Encoding: br when compression enabled and client accepts br' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'br, gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: true)

      expect(dispatcher.response['Content-Encoding']).to eq('br')
      expect(dispatcher.response['Vary']).to eq('Accept-Encoding')
    end

    it 'sets Content-Encoding: gzip when compression enabled and client accepts gzip only' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: true)

      expect(dispatcher.response['Content-Encoding']).to eq('gzip')
      expect(dispatcher.response['Vary']).to eq('Accept-Encoding')
    end

    it 'does not set Content-Encoding when compression enabled but no Accept-Encoding' do
      request = build_request('/events')
      dispatcher = Datastar.new(request:, response:, view_context:, compression: true)

      expect(dispatcher.response['Content-Encoding']).to be_nil
      expect(dispatcher.response['Vary']).to be_nil
    end

    it 'does not set Content-Encoding when compression disabled' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'br, gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: false)

      expect(dispatcher.response['Content-Encoding']).to be_nil
    end

    it 'streams gzip-compressed data that decompresses correctly' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: true, heartbeat: false)

      dispatcher.patch_signals(foo: 'bar')

      raw_socket = BinarySocket.new
      dispatcher.response.body.call(raw_socket)

      decompressed = Zlib::Inflate.new(31).inflate(raw_socket.bytes)
      expect(decompressed).to include('datastar-patch-signals')
      expect(decompressed).to include('"foo":"bar"')
    end

    it 'streams brotli-compressed data that decompresses correctly' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'br' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: true, heartbeat: false)

      dispatcher.patch_signals(foo: 'bar')

      raw_socket = BinarySocket.new
      dispatcher.response.body.call(raw_socket)

      decompressed = Brotli.inflate(raw_socket.bytes)
      expect(decompressed).to include('datastar-patch-signals')
      expect(decompressed).to include('"foo":"bar"')
    end

    it 'respects compression order as preference (gzip first)' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'br, gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: [:gzip, :br])

      expect(dispatcher.response['Content-Encoding']).to eq('gzip')
    end

    it 'respects compression as array of enabled encodings' do
      request = build_request('/events', headers: { 'HTTP_ACCEPT_ENCODING' => 'br, gzip' })
      dispatcher = Datastar.new(request:, response:, view_context:, compression: [:gzip])

      expect(dispatcher.response['Content-Encoding']).to eq('gzip')
    end
  end

  describe ':generator_class' do
    it 'defaults to Datastar::ServerSentEventGenerator' do
      expect(Datastar::ServerSentEventGenerator).to receive(:new).and_call_original

      dispatcher = Datastar.new(request:, response:, view_context:)
      dispatcher.patch_signals(foo: 'bar')

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
    end

    it 'instantiates the provided class for one-off responses (stream_one)' do
      custom = Class.new(Datastar::ServerSentEventGenerator)
      expect(custom).to receive(:new).and_call_original

      dispatcher = Datastar.new(request:, response:, view_context:, generator_class: custom)
      dispatcher.patch_signals(foo: 'bar')

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
    end

    it 'instantiates the provided class for every concurrent stream and the connection generator (stream_many)' do
      custom = Class.new(Datastar::ServerSentEventGenerator)
      # 1 connection generator + 2 per-stream generators = 3
      expect(custom).to receive(:new).at_least(3).times.and_call_original

      dispatcher = Datastar.new(request:, response:, view_context:, generator_class: custom, heartbeat: false)
      dispatcher.stream { |sse| sse.patch_signals(foo: 1) }
      dispatcher.stream { |sse| sse.patch_signals(bar: 2) }

      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.wait_for_close
    end

    it 'lets a subclass observe every event written to the stream' do
      observed = []
      custom = Class.new(Datastar::ServerSentEventGenerator) do
        define_method(:write) do |buffer|
          observed << buffer.dup
          super(buffer)
        end
      end

      dispatcher = Datastar.new(request:, response:, view_context:, generator_class: custom)
      dispatcher.patch_signals(foo: 'bar')

      socket = TestSocket.new
      dispatcher.response.body.call(socket)

      expect(observed.size).to eq(1)
      expect(observed.first).to include('datastar-patch-signals')
    end
  end

  describe 'SSE injection guards' do
    # WHATWG SSE parser splits on \r, \n, or \r\n. Caller-supplied strings
    # must never be able to split or forge fields no matter where they
    # appear in the API surface.
    BROWSER_LINE_BREAK = /\r\n|\r|\n/

    def stream_lines(dispatcher)
      socket = TestSocket.new
      dispatcher.response.body.call(socket)
      socket.lines.join.split(BROWSER_LINE_BREAK)
    end

    describe '#patch_elements element body' do
      it 'strips bare \r from element bodies' do
        dispatcher.patch_elements("<li>safe</li>\revent: forged\ndata: elements <pwned>")
        lines = stream_lines(dispatcher)

        # Exactly one event header (the legitimate one)
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
        # The injected `event: forged` is now concatenated into the parent data line
        expect(lines).to include(a_string_matching(/^data: elements .*event: forged/))
      end

      it 'preserves \n inside element bodies (used as the line splitter)' do
        dispatcher.patch_elements("<div>\n<span>hi</span>\n</div>")
        lines = stream_lines(dispatcher)
        expect(lines).to include('data: elements <div>')
        expect(lines).to include('data: elements <span>hi</span>')
        expect(lines).to include('data: elements </div>')
      end
    end

    describe '#patch_elements scalar option' do
      it 'strips \r from scalar option values' do
        dispatcher.patch_elements('<p>x</p>', selector: "#a\rinjected: evil")
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
        expect(lines).to include(a_string_matching(/^data: selector #ainjected: evil/))
      end

      it 'strips \n from scalar option values' do
        dispatcher.patch_elements('<p>x</p>', selector: "#b\ninjected: evil")
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
        expect(lines).to include(a_string_matching(/^data: selector #binjected: evil/))
      end

      it 'strips \r\n from scalar option values' do
        dispatcher.patch_elements('<p>x</p>', selector: "#c\r\ninjected: evil")
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
      end
    end

    describe '#patch_elements array option' do
      it 'strips line terminators from each entry' do
        dispatcher.patch_elements('<p>x</p>', selector: ["#a\rinjected: evil", "#b\nfoo: bar"])
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
        expect(lines).not_to include('foo: bar')
        expect(lines.grep(/^event:/).size).to eq(1)
      end
    end

    describe '#patch_elements hash option entries' do
      it 'strips line terminators from hash entry values' do
        dispatcher.patch_elements('<p>x</p>', extra: { key: "v\revent: forged" })
        lines = stream_lines(dispatcher)
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
      end
    end

    describe '#patch_signals' do
      it 'strips \r from String signal payloads' do
        dispatcher.patch_signals("{\"a\":1}\revent: forged\ndata: signals {\"b\":2}")
        lines = stream_lines(dispatcher)
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-signals'])
      end

      it 'safely encodes Hash signal values containing line terminators (JSON)' do
        dispatcher.patch_signals(msg: "hi\revent: forged\nbye")
        lines = stream_lines(dispatcher)
        # JSON.dump produces a single safe data: signals line
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-signals'])
        expect(lines.grep(/^data: signals/).size).to eq(1)
      end

      it 'strips line terminators from option values' do
        dispatcher.patch_signals({ foo: 'bar' }, event_id: "1\rinjected: evil")
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
      end
    end

    describe '#remove_elements' do
      it 'strips \r from selector' do
        dispatcher.remove_elements("#a\rinjected: evil")
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
      end

      it 'strips \n from each selector when given an array' do
        dispatcher.remove_elements(["#a\ninjected: evil", "#b"])
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
      end
    end

    describe '#execute_script' do
      it 'strips \r from the script body' do
        dispatcher.execute_script("safe()\revent: forged\ndata: elements <pwned>")
        lines = stream_lines(dispatcher)
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
      end

      it 'preserves multi-line script bodies (\n is allowed in JS)' do
        dispatcher.execute_script("a()\nb()")
        lines = stream_lines(dispatcher)
        # The script tag spans multiple data: elements lines, all under the same event
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
        expect(lines.grep(/^data: elements/).size).to be >= 2
      end

      it 'strips line terminators from attribute values so the script tag stays single-line' do
        dispatcher.execute_script(
          "alert('hi')",
          attributes: { type: "text/javascript\nfoo: bar", custom: "v\rinjected: evil" }
        )
        lines = stream_lines(dispatcher)
        expect(lines).not_to include('injected: evil')
        # Tag stays on one data: elements line (no attribute-induced split)
        expect(lines.grep(/^data: elements/).size).to eq(1)
      end
    end

    describe '#redirect' do
      it 'strips \r from the URL (URL ends up inside a script body)' do
        dispatcher.redirect("/safe\revent: forged")
        lines = stream_lines(dispatcher)
        expect(lines.grep(/^event:/)).to eq(['event: datastar-patch-elements'])
      end
    end

    describe 'issue #18 reproduction' do
      it 'absorbs all CR/LF injection attempts into legitimate data: lines' do
        # Mirrors the reproduction from the upstream issue
        dispatcher.stream(heartbeat: false) do |sse|
          sse.patch_elements("<li>safe</li>\revent: forged\ndata: elements <pwned>")
          sse.patch_elements("<p>x</p>", selector: "#a\rinjected: evil")
          sse.patch_elements("<p>x</p>", selector: "#b\ninjected: evil")
          sse.execute_script("safe()\revent: forged\ndata: elements <pwned>")
        end

        socket = TestSocket.new
        dispatcher.response.body.call(socket)
        socket.wait_for_close

        lines = socket.lines.join.split(BROWSER_LINE_BREAK)

        # Exactly 4 legitimate event: headers (one per method call) — no forged ones
        event_lines = lines.grep(/^event:/)
        expect(event_lines.size).to eq(4)
        expect(event_lines).to all(start_with('event: datastar-'))

        # No standalone "injected:" field
        expect(lines).not_to include(a_string_matching(/^injected:/))
      end
    end
  end

  private

  # Binary socket for compression tests
  class BinarySocket
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

  def build_request(path, method: 'GET', body: nil, content_type: 'application/json', accept: 'text/event-stream', headers: {})
    headers = { 
      'HTTP_ACCEPT' => accept, 
      'CONTENT_TYPE' => content_type,
      'REQUEST_METHOD' => method,
      Rack::RACK_INPUT => body ? StringIO.new(body) : nil
    }.merge(headers)

    Rack::Request.new(Rack::MockRequest.env_for(path, headers))
  end
end
