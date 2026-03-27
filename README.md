# ObservLib

ObservLib is a comprehensive OpenTelemetry observability library for Elixir, providing a unified interface for distributed tracing, metrics collection, and structured logging. It simplifies integration with OpenTelemetry and OTLP exporters, allowing you to instrument your Elixir applications with minimal configuration.

## Features

- **Distributed Tracing**: Create and manage spans for distributed tracing with automatic context propagation
- **Metrics Collection**: Record counters, gauges, histograms, and up-down counters with OpenTelemetry integration
- **Structured Logging**: Emit logs with contextual attributes and OpenTelemetry integration
- **OTLP Export**: Built-in support for exporting traces, metrics, and logs via OTLP to any compatible backend
- **Resource Attributes**: Configure service metadata and resource attributes for proper telemetry identification
- **Configuration Management**: Centralized configuration with sensible defaults and runtime customization

## Installation

Add `observlib` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:observlib, "~> 0.1.0"}
  ]
end
```

Then run `mix deps.get` to fetch the dependencies.

## Quick Start

### 1. Configure ObservLib

Add configuration to your `config/config.exs`:

```elixir
config :observlib,
  service_name: "my_application",
  otlp_endpoint: "http://localhost:4318",
  resource_attributes: %{
    "service.version" => "1.0.0",
    "deployment.environment" => "production"
  }
```

### 2. Initialize in your application

ObservLib is automatically initialized via the Application supervisor. Just ensure your application starts:

```elixir
# This is typically already done in mix.exs
def application do
  [
    extra_applications: [:logger],
    mod: {MyApp.Application, []}
  ]
end
```

### 3. Use ObservLib in your code

```elixir
# Distributed tracing
span = ObservLib.Traces.start_span("database_query", %{"db.system" => "postgresql"})
# ... perform work ...
ObservLib.Traces.end_span(span)

# Or use with_span for automatic cleanup
ObservLib.Traces.with_span("api_request", %{"http.method" => "GET"}, fn ->
  # ... your code ...
  {:ok, result}
end)

# Metrics
ObservLib.Metrics.counter("http.requests", 1, %{method: "GET", status: 200})
ObservLib.Metrics.gauge("memory.usage", 1024.5, %{type: "heap"})
ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})

# Structured logging
ObservLib.Logs.info("Request processed", request_id: "abc-123", duration_ms: 42)
ObservLib.Logs.error("Connection failed", error: "timeout", retry_count: 3)
```

## Configuration

### Basic Configuration

```elixir
config :observlib,
  service_name: "my_service",
  otlp_endpoint: "http://localhost:4318",
  resource_attributes: %{}
```

### Full Configuration Example

```elixir
config :observlib,
  # Required: Service name for telemetry identification
  service_name: "api_server",

  # Optional: OTLP collector HTTP endpoint
  # Defaults to nil (no export)
  otlp_endpoint: "http://otel-collector:4318",

  # Optional: Specific endpoints for each signal type
  # Falls back to otlp_endpoint if not specified
  otlp_traces_endpoint: "http://traces-collector:4318",
  otlp_metrics_endpoint: "http://metrics-collector:4318",
  otlp_logs_endpoint: "http://logs-collector:4318",

  # Optional: Custom headers for OTLP requests
  otlp_headers: %{
    "Authorization" => "Bearer token123"
  },

  # Optional: OTLP request timeout in milliseconds
  otlp_timeout: 10000,

  # Optional: Batch size for OTLP exporters
  batch_size: 512,

  # Optional: Batch timeout in milliseconds
  batch_timeout: 5000,

  # Optional: Pyroscope endpoint for profiling integration
  pyroscope_endpoint: "http://pyroscope:4040",

  # Optional: Additional resource attributes for identification
  resource_attributes: %{
    "service.version" => "1.0.0",
    "deployment.environment" => "production",
    "service.namespace" => "platform"
  }
```

### Environment-based Configuration

```elixir
config :observlib,
  service_name: "my_service",
  otlp_endpoint: System.get_env("OTLP_ENDPOINT", "http://localhost:4318"),
  resource_attributes: %{
    "deployment.environment" => System.get_env("ENV", "development")
  }
```

## Usage Examples

### Traces

```elixir
# Simple span
span = ObservLib.Traces.start_span("fetch_user")
ObservLib.Traces.end_span(span)

# Span with attributes
span = ObservLib.Traces.start_span("db_query", %{
  "db.system" => "postgresql",
  "db.statement" => "SELECT * FROM users",
  "db.rows_returned" => 100
})
ObservLib.Traces.end_span(span)

# Automatic span management
result = ObservLib.Traces.with_span("http_request", %{"http.method" => "POST"}, fn ->
  # Code here runs inside the span
  {:ok, data}
end)

# Set span attributes and status
span = ObservLib.Traces.start_span("operation")
:otel_tracer.set_current_span(span)
ObservLib.Traces.set_attribute("http.status_code", 200)
ObservLib.Traces.set_status(:ok)
ObservLib.Traces.end_span(span)

# Handle errors
try do
  raise "Something went wrong"
rescue
  e ->
    span = ObservLib.Traces.start_span("failing_operation")
    :otel_tracer.set_current_span(span)
    ObservLib.Traces.record_exception(e)
    ObservLib.Traces.set_status(:error, "Exception occurred")
    ObservLib.Traces.end_span(span)
end
```

### Metrics

```elixir
# Counter - monotonically increasing
ObservLib.Metrics.counter("http.requests", 1, %{method: "GET"})
ObservLib.Metrics.counter("login.attempts", 1, %{result: "success"})

# Gauge - point-in-time value
ObservLib.Metrics.gauge("memory.usage", 2048, %{type: "heap"})
ObservLib.Metrics.gauge("queue.depth", 42, %{queue: "default"})
ObservLib.Metrics.gauge("active.connections", 156, %{protocol: "http"})

# Histogram - distribution of values
ObservLib.Metrics.histogram("http.request.duration", 45.2, %{method: "GET"})
ObservLib.Metrics.histogram("db.query.time", 123.4, %{table: "users"})
ObservLib.Metrics.histogram("cache.lookup.time", 5.1, %{hit: true})

# Up-down counter - can increase or decrease
ObservLib.Metrics.up_down_counter("active.sessions", 1, %{})
ObservLib.Metrics.up_down_counter("active.sessions", -1, %{})

# Register metrics for documentation
ObservLib.Metrics.register_counter("http.requests",
  unit: :count,
  description: "Total HTTP requests processed"
)

ObservLib.Metrics.register_histogram("http.request.duration",
  unit: :millisecond,
  description: "HTTP request duration distribution"
)

# List registered metrics
metrics = ObservLib.Metrics.list_registered_metrics()
```

### Logs

```elixir
# Simple logging
ObservLib.Logs.debug("Cache miss", key: "user:123")
ObservLib.Logs.info("User logged in", user_id: 456)
ObservLib.Logs.warn("High memory usage", memory_mb: 1024)
ObservLib.Logs.error("Database connection failed", error: "timeout")

# Logging with map attributes
ObservLib.Logs.info("Request processed", %{
  request_id: "abc-123",
  duration_ms: 42,
  status: 200
})

# Generic log function with level
ObservLib.Logs.log(:info, "Custom message", level: :info, custom: "value")

# Contextual logging - attributes persist across multiple log calls
ObservLib.Logs.with_context(%{request_id: "req-789"}, fn ->
  ObservLib.Logs.info("Starting processing")
  ObservLib.Logs.debug("Step 1 complete")
  ObservLib.Logs.info("Finished processing")
  # All logs include request_id: "req-789"
end)

# Nested contexts
ObservLib.Logs.with_context(%{user_id: 100}, fn ->
  ObservLib.Logs.info("User action started")

  ObservLib.Logs.with_context(%{action: "login"}, fn ->
    ObservLib.Logs.info("Processing login")
    # Logs include both user_id and action
  end)
end)

# Attach logger handler for OpenTelemetry integration
ObservLib.Logs.attach_logger_handler()
```

## OTLP Exporter Configuration

### Using Jaeger (Traces)

```elixir
config :observlib,
  service_name: "my_app",
  otlp_endpoint: "http://jaeger:4318"

# Jaeger will receive traces at http://jaeger:4318/v1/traces
```

### Using Prometheus (Metrics)

```elixir
config :observlib,
  service_name: "my_app",
  otlp_endpoint: "http://prometheus-collector:4318"

# Prometheus will receive metrics at http://prometheus-collector:4318/v1/metrics
```

### Using Loki (Logs)

```elixir
config :observlib,
  service_name: "my_app",
  otlp_endpoint: "http://loki:4318"

# Loki will receive logs at http://loki:4318/v1/logs
```

### Using OpenTelemetry Collector (All signals)

```elixir
config :observlib,
  service_name: "my_app",
  otlp_endpoint: "http://otel-collector:4318",

  # Optional: Override specific endpoints
  otlp_traces_endpoint: "http://traces-backend:4318",
  otlp_metrics_endpoint: "http://metrics-backend:4318",
  otlp_logs_endpoint: "http://logs-backend:4318"
```

## Resource Attributes

Resource attributes provide metadata about your service and deployment. They help identify and organize telemetry data in backends.

### Standard Attributes

```elixir
config :observlib,
  service_name: "api_server",
  resource_attributes: %{
    # Service version
    "service.version" => "1.0.0",

    # Deployment environment
    "deployment.environment" => "production",

    # Service namespace/group
    "service.namespace" => "platform",

    # Service instance identifier
    "service.instance.id" => "server-01",

    # Process identifier
    "process.pid" => "#{System.os_pid()}",

    # Host information
    "host.name" => "host-01",
    "host.os.name" => "linux",

    # Kubernetes attributes (if applicable)
    "k8s.deployment.name" => "api-deployment",
    "k8s.pod.name" => "api-pod-xyz",
    "k8s.namespace.name" => "production"
  }
```

### Dynamic Resource Attributes

```elixir
config :observlib,
  service_name: "my_app",
  resource_attributes: %{
    "service.version" => Application.spec(:my_app)[:vsn] |> to_string(),
    "deployment.environment" => config(:my_app)[:env] || "development",
    "process.pid" => "#{System.os_pid()}"
  }
```

## Troubleshooting

### Issue: "service_name must be a non-empty string"

**Cause**: The `service_name` configuration is missing or empty.

**Solution**: Add `service_name` to your `config/config.exs`:

```elixir
config :observlib,
  service_name: "my_service"
```

### Issue: Telemetry data not appearing in backend

**Cause**: OTLP endpoint not configured or unreachable.

**Solution**:
1. Check that `otlp_endpoint` is configured in `config/config.exs`
2. Verify the endpoint is accessible from your application
3. Check application logs for connection errors

```elixir
config :observlib,
  service_name: "my_app",
  otlp_endpoint: "http://otel-collector:4318"

# Test connectivity
:gen_tcp.connect('localhost', 4318, [])
```

### Issue: High memory usage with metrics

**Cause**: Large metric values or too many unique attribute combinations.

**Solution**:
1. Reduce batch size if needed
2. Increase batch timeout to flush more frequently
3. Limit the number of unique attribute combinations

```elixir
config :observlib,
  batch_size: 256,        # Smaller batches
  batch_timeout: 2000     # Flush every 2 seconds
```

### Issue: Traces/metrics not captured

**Cause**: OpenTelemetry not properly initialized.

**Solution**: Ensure your application properly starts the supervision tree:

```elixir
def start(_type, _args) do
  children = [
    # Your app children...
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Documentation

For detailed API documentation, see:
- `ObservLib` - Main module with configuration functions
- `ObservLib.Traces` - Distributed tracing API
- `ObservLib.Metrics` - Metrics collection API
- `ObservLib.Logs` - Structured logging API
- `ObservLib.Config` - Configuration management

Run `mix docs` to generate full documentation locally.
