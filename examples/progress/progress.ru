require 'bundler'
Bundler.setup(:test)

require 'datastar'

# This is a demo Rack app to showcase patching components and signals
# from the server to the client.
# To run:
#
#   # install dependencies
#   bundle install
#   # run this endpoint with Puma server
#   bundle exec puma ./progress.ru
#
#   Then open http://localhost:9292
#
# A Web Component for circular progress
# Progress is controlled by a `progress` signal
PROGRESS = <<~JAVASCRIPT
  class CircularProgress extends HTMLElement {
      constructor() {
          super();
          this.attachShadow({ mode: 'open' });
          this._progress = 0;
          this.radius = 90;
          this.circumference = 2 * Math.PI * this.radius;
      }

      static get observedAttributes() {
          return ['progress'];
      }

      get progress() {
          return this._progress;
      }

      attributeChangedCallback(name, oldValue, newValue) {
          if (name === 'progress' && oldValue !== newValue) {
              this._progress = Math.max(0, Math.min(100, parseFloat(newValue) || 0));
              this.updateProgress();
          }
     }

      connectedCallback() {
          this.render();
      }

      render() {
          this.shadowRoot.innerHTML = `
              <slot></slot>
              <svg
                  width="200"
                  height="200"
                  viewBox="-25 -25 250 250"
                  style="transform: rotate(-90deg)"
              >
                  <!-- Background circle -->
                  <circle
                      r="${this.radius}"
                      cx="100"
                      cy="100"
                      fill="transparent"
                      stroke="#e0e0e0"
                      stroke-width="16px"
                      stroke-dasharray="${this.circumference}px"
                      stroke-dashoffset="${this.circumference}px"
                  ></circle>
                  
                  <!-- Progress circle -->
                  <circle
                      id="progress-circle"
                      r="${this.radius}"
                      cx="100"
                      cy="100"
                      fill="transparent"
                      stroke="#6bdba7"
                      stroke-width="16px"
                      stroke-linecap="round"
                      stroke-dasharray="${this.circumference}px"
                      style="transition: stroke-dashoffset 0.1s ease-in-out"
                  ></circle>
                  
                  <!-- Progress text -->
                  <text
                      id="progress-text"
                      x="44px"
                      y="115px"
                      fill="#6bdba7"
                      font-size="52px"
                      font-weight="bold"
                      style="transform:rotate(90deg) translate(0px, -196px)"
                  ></text>
              </svg>
          `;
      }

      updateProgress() {
          if (!this.shadowRoot) return;

          const progressCircle = this.shadowRoot.getElementById('progress-circle');
          const progressText = this.shadowRoot.getElementById('progress-text');
          
          if (progressCircle && progressText) {
              // Calculate stroke-dashoffset based on progress
              const offset = this.circumference - (this._progress / 100) * this.circumference;
              progressCircle.style.strokeDashoffset = `${offset}px`;
              
              // Update text
              progressText.textContent = `${Math.round(this._progress)}%`;
          }
      }
  }

  // Register the custom element
  customElements.define('circular-progress', CircularProgress);
JAVASCRIPT

# The initial index HTML page
INDEX = <<~HTML
  <!DOCTYPE html>
  <html>
    <head>
      <meta charset="UTF-8">
      <title>Datastar progress-circle</title>
      <style>
        body {
            font-family: Arial, sans-serif;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .demo-container {
            max-width: 800px;
            margin: 0 auto;
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        }
        button {
            background: linear-gradient(135deg, #6bdba7 0%, #5bc399 100%);
            color: white;
            border: none;
            padding: 12px 24px;
            font-size: 16px;
            font-weight: 600;
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.2s ease;
            box-shadow: 0 2px 4px rgba(107, 219, 167, 0.3);
            margin-bottom: 20px;
        }
        button:hover:not([aria-disabled="true"]) {
            background: linear-gradient(135deg, #5bc399 0%, #4db389 100%);
            transform: translateY(-1px);
            box-shadow: 0 4px 8px rgba(107, 219, 167, 0.4);
        }
        button:active:not([aria-disabled="true"]) {
            transform: translateY(0);
            box-shadow: 0 2px 4px rgba(107, 219, 167, 0.3);
        }
        button[aria-disabled="true"] {
            background: #e0e0e0;
            color: #999;
            cursor: not-allowed;
            box-shadow: none;
        }
        .col {
            flex: 1;
            padding: 0 15px;
            min-height: 340px;
        }
        .col:first-child {
            padding-left: 0;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }
        .col:last-child {
            padding-right: 0;
        }
        @media (min-width: 768px) {
            .demo-container {
                display: flex;
                gap: 30px;
            }
        }
        #activity {
            overflow-y: auto;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            padding: 16px;
            background: #fafafa;
        }
        .a-item {
            background: white;
            border: 1px solid #e8e8e8;
            border-radius: 6px;
            padding: 12px 16px;
            margin-bottom: 8px;
            font-size: 14px;
            color: #333;
            box-shadow: 0 1px 2px rgba(0,0,0,0.05);
            transition: all 0.2s ease;
        }
        .a-item:last-child {
            margin-bottom: 0;
        }
        .a-item:hover {
            background: #f8f9fa;
            border-color: #d0d0d0;
        }
        .a-item .time {
            display: block;
            font-size: 11px;
            color: #888;
            margin-bottom: 4px;
            font-family: monospace;
        }
        .a-item.done {
            background: #f0f9f4;
            border-color: #6bdba7;
            color: #2d5a3d;
        }
        .a-item.done .time {
            color: #5a8a6a;
        }
        #title {
          text-align: center;
        }
      </style>
      <script type="module">#{PROGRESS}</script>
      <script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.6/bundles/datastar.js"></script>
    </head>
    <body>
      <div class="demo-container">
        <div class="col">
          <p>
            <button 
                data-indicator:_fetching 
                data-on:click="!$_fetching && @get('/', {openWhenHidden: true})"
                data-attr:aria-disabled="`${$_fetching}`"
              >Start</button>
          </p>
          <div id="work">
          </div>
        </div>

        <div class="col" id="activity">
        </div>
      </div>
    </body>
  <html>
HTML

trap('INT') { exit }

# The server-side app
# It handles the initial page load and serves the initial HTML.
# It also handles Datastar SSE requests and streams updates to the client.
run do |env|
  datastar = Datastar
             .from_rack_env(env)
             .on_connect do |socket|
    p ['connect', socket]
  end.on_server_disconnect do |socket|
    p ['server disconnect', socket]
  end.on_client_disconnect do |socket|
    p ['client disconnect', socket]
  end.on_error do |error|
    p ['exception', error]
    puts error.backtrace.join("\n")
  end

  if datastar.sse? # <= we're in a Datastar SSE request

    # A thread to simulate the work and control the progress component
    datastar.stream do |sse|
      # Reset activity
      sse.patch_elements(%(<div id="activity" class="col"></div>))

      # step 1: add the initial progress component to the DOM
      sse.patch_elements(%(<circular-progress id="work" data-bind:progress data-attr:progress="$progress"><h1 id="title">Processing...</h1></circular-progress>))

      # step 2: simulate work and update the progress signal
      0.upto(100) do |i|
        sleep rand(0.03..0.09) # Simulate work
        sse.patch_signals(progress: i)
      end

      # step 3: update the DOM to indicate completion
      # sse.patch_elements(%(<p id="work">Done!</p>))
      sse.patch_elements(%(<div class="a-item done"><span class="time">#{Time.now.iso8601}</span>Done!</div>), selector: '#activity', mode: 'append')
      sse.patch_elements(%(<h1 id="title">Done!</h1>))
    end

    # A second thread to push activity updates to the UI
    datastar.stream do |sse|
      ['Work started', 'Connecting to API', 'downloading data', 'processing data'].each do |activity|
        sse.patch_elements(%(<div class="a-item"><span class="time">#{Time.now.iso8601}</span>#{activity}</div>), selector: '#activity', mode: 'append')
        sleep rand(0.5..1.7) # Simulate time taken for each activity
      end
    end
  else # <= We're in a regular HTTP request
    [200, { 'content-type' => 'text/html' }, [INDEX]]
  end
end
