# Datastar Ruby SDK

Implement the [Datastart SSE procotocol](https://data-star.dev/reference/sse_events) in Ruby. It can be used in any Rack handler, and Rails controllers.

## Installation

Add this gem to your `Gemfile`

```bash
gem 'datastar'
```

Or point your `Gemfile` to the source

```bash
gem 'datastar', git: 'https://github.com/starfederation/datastar', glob: 'sdk/ruby/*.gemspec'
```

## Usage

### Initialize the Datastar dispatcher

In your Rack handler or Rails controller:

```ruby
# Rails controllers, as well as Sinatra and others, 
# already have request and response objects.
# `view_context` is optional and is used to render Rails templates.
# Or view components that need access to helpers, routes, or any other context.

datastar = Datastar.new(request:, response:, view_context:)

# In a Rack handler, you can instantiate from the Rack env
datastar = Datastar.from_rack_env(env)
```

### Sending updates to the browser

There are two ways to use this gem in HTTP handlers:

* One-off responses, where you want to send a single update down to the browser.
* Streaming responses, where you want to send multiple updates down to the browser.

#### One-off update:

```ruby
datastar.patch_elements(%(<h1 id="title">Hello, World!</h1>))
```
In this mode, the response is closed after the fragment is sent.

#### Streaming updates

```ruby
datastar.stream do |sse|
  sse.patch_elements(%(<h1 id="title">Hello, World!</h1>))
  # Streaming multiple updates
  100.times do |i|
    sleep 1
    sse.patch_elements(%(<h1 id="title">Hello, World #{i}!</h1>))
  end
end
```
In this mode, the response is kept open until `stream` blocks have finished.

#### Concurrent streaming blocks

Multiple `stream` blocks will be launched in threads/fibers, and will run concurrently.
Their updates are linearized and sent to the browser as they are produced.

```ruby
# Stream to the browser from two concurrent threads
datastar.stream do |sse|
  100.times do |i|
    sleep 1
    sse.patch_elements(%(<h1 id="slow">#{i}!</h1>))
  end
end

datastar.stream do |sse|
  1000.times do |i|
    sleep 0.1
    sse.patch_elements(%(<h1 id="fast">#{i}!</h1>))
  end
end
```

See the [examples](https://github.com/starfederation/datastar/tree/main/examples/ruby) directory.

### Datastar methods

All these methods are available in both the one-off and the streaming modes.

#### `patch_elements`
See https://data-star.dev/reference/sse_events#datastar-patch-elements

```ruby
sse.patch_elements(%(<div id="foo">\n<span>hello</span>\n</div>))

# or a Phlex view object
sse.patch_elements(UserComponent.new)

# Or pass options
sse.patch_elements(
  %(<div id="foo">\n<span>hello</span>\n</div>),
  mode: 'append'
)
```

You can patch multiple elements at once by passing an array of elements (or components):

```ruby
sse.patch_elements([
  %(<div id="foo">\n<span>hello</span>\n</div>),
  %(<div id="bar">\n<span>world</span>\n</div>)
])
```

#### `remove_elements`

Sugar on top of `#patch_elements`
 See https://data-star.dev/reference/sse_events#datastar-patch-elements

```ruby
sse.remove_elements('#users')
```

#### `patch_signals`
 See https://data-star.dev/reference/sse_events#datastar-patch-signals

```ruby
sse.patch_signals(count: 4, user: { name: 'John' })
```

#### `remove_signals`

Sugar on top of `#patch_signals`

```ruby
sse.remove_signals(['user.name', 'user.email'])
```

#### `execute_script`

Sugar on top of `#patch_elements`. Appends a temporary `<script>` tag to the DOM, which will execute the script in the browser.

```ruby
sse.execute_script(%(alert('Hello World!'))
```

Pass `attributes` that will be added to the `<script>` tag:

```ruby
sse.execute_script(%(alert('Hello World!')), attributes: { type: 'text/javascript' })
```

These script tags are automatically removed after execution, so they can be used to run one-off scripts in the browser. Pass `auto_remove: false` if you want to keep the script tag in the DOM.

```ruby
sse.execute_script(%(alert('Hello World!')), auto_remove: false)
```

#### `signals`
See https://data-star.dev/guide/reactive_signals

Returns signals sent by the browser.

```ruby
sse.signals # => { user: { name: 'John' } }
```

#### `redirect`
This is just a helper to send a script to update the browser's location.

```ruby
sse.redirect('/new_location')
```

### Lifecycle callbacks

#### `on_connect`
Register server-side code to run when the connection is first handled.

```ruby
datastar.on_connect do
  puts 'A user has connected'
end
```

#### `on_client_disconnect`
Register server-side code to run when the connection is closed by the client

```ruby
datastar.on_client_disconnect do
  puts 'A user has disconnected connected'
end
```

This callback's behaviour depends on the configured [heartbeat](#heartbeat)

#### `on_server_disconnect`

Register server-side code to run when the connection is closed by the server.
Ie when the served is done streaming without errors.

```ruby
datastar.on_server_disconnect do
  puts 'Server is done streaming'
end
```

#### `on_error`
Ruby code to handle any exceptions raised by streaming blocks.

```ruby
datastar.on_error do |exception|
  Sentry.notify(exception)
end
```
Note that this callback can be [configured globally](#global-configuration), too.

### heartbeat

By default, streaming responses (using the `#stream` block) launch a background thread/fiber to periodically check the connection.

This is because the browser could have disconnected during a long-lived, idle connection (for example waiting on an event bus).

The default heartbeat is 3 seconds, and it will close the connection and trigger [on_client_disconnect](#on_client_disconnect) callbacks if the client has disconnected.

In cases where a streaming block doesn't need a heartbeat and you want to save precious threads (for example a regular ticker update, ie non-idle), you can disable the heartbeat:

```ruby
datastar = Datastar.new(request:, response:, view_context:, heartbeat: false)

datastar.stream do |sse|
  100.times do |i|
    sleep 1
    sse.merge_signals count: i
  end
end
```

You can also set it to a different number (in seconds)

```ruby
heartbeat: 0.5
```

#### Manual connection check

If you want to check connection status on your own, you can disable the heartbeat and use `sse.check_connection!`, which will close the connection and trigger callbacks if the client is disconnected.

```ruby
datastar = Datastar.new(request:, response:, view_context:, heartbeat: false)

datastar.stream do |sse|
  # The event bus implementaton will check connection status when idle
  # by calling #check_connection! on it
  EventBus.subscribe('channel', sse) do |event|
    sse.merge_signals eventName: event.name
  end
end
```

### Global configuration

```ruby
Datastar.configure do |config|
  # Global on_error callback
  # Can be overriden on specific instances
  config.on_error do |exception|
    Sentry.notify(exception)
  end
  
  # Global heartbeat interval (or false, to disable)
  # Can be overriden on specific instances
  config.heartbeat = 0.3
end
```

### Rendering Rails templates

In Rails, make sure to initialize Datastar with the `view_context` in a controller.
This is so that rendered templates, components or views have access to helpers, routes, etc.

```ruby
datastar = Datastar.new(request:, response:, view_context:)

datastar.stream do |sse|
  10.times do |i|
    sleep 1
    tpl = render_to_string('events/user', layout: false, locals: { name: "David #{i}" })
    sse.patch_elements tpl
  end
end
```

### Rendering Phlex components

`#patch_elements` supports [Phlex](https://www.phlex.fun) component instances.

```ruby
sse.patch_elements(UserComponent.new(user: User.first))
```

### Rendering ViewComponent instances

`#patch_elements` also works with [ViewComponent](https://viewcomponent.org) instances.

```ruby
sse.patch_elements(UserViewComponent.new(user: User.first))
```

### Rendering `#render_in(view_context)` interfaces

Any object that supports the `#render_in(view_context) => String` API can be used as a fragment.

```ruby
class MyComponent
  def initialize(name)
    @name = name
  end

  def render_in(view_context)
    "<div>Hello #{@name}</div>""
  end
end
```

```ruby
sse.patch_elements MyComponent.new('Joe')
```



### Tests

```ruby
bundle exec rspec
```

#### Running Datastar's SDK test suite

Install dependencies.
```bash
bundle install
```

From this library's root, run the bundled-in test Rack app:

```bash
bundle puma -p 8000 examples/test.ru
```

From the main [Datastar](https://github.com/starfederation/datastar) repo (you'll need Go installed)

```bash
cd sdk/tests
go run ./cmd/datastar-sdk-tests -server http://localhost:8000 
```

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Building

To build `consts.rb` file from template, run Docker and run `make task build`

The template is located at `build/consts_ruby.gtpl`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/starfederation/datastar.
