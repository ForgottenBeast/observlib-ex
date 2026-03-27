# Getting Started with ObservLib

This guide walks you through installing and configuring ObservLib for your Elixir application.

## Installation

Add `observlib` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:observlib, "~> 0.1.0"}
  ]
end
```

Fetch dependencies:

```bash
mix deps.get
```

## Basic Configuration

Add minimal configuration to `config/config.exs`:

```elixir
config :observlib,
  service_name: "my_application"
```

That's it! ObservLib starts automatically with your application.

## First Trace

Create a traced operation:

```elixir
defmodule MyApp.Users do
  def get_user(id) do
    ObservLib.traced("get_user", %{"user.id" => id}, fn ->
      # Your database lookup
      {:ok, %{id: id, name: "Alice"}}
    end)
  end
end
```

Or use the lower-level API:

```elixir
span = ObservLib.Traces.start_span("database_query", %{"db.system" => "postgresql"})
result = Repo.get(User, id)
ObservLib.Traces.end_span(span)
```

## First Metric

Record metrics in your application:

```elixir
# Count events
ObservLib.counter("http.requests", 1, %{method: "GET", status: 200})

# Track current values
ObservLib.gauge("queue.depth", 42, %{queue: "default"})

# Record distributions (e.g., latencies)
ObservLib.histogram("http.request.duration", 45.2, %{method: "GET"})
```

## First Log

Emit structured logs:

```elixir
ObservLib.Logs.info("User logged in", user_id: 123, ip: "192.168.1.1")
ObservLib.Logs.error("Connection failed", error: "timeout", retry_count: 3)
```

Add context to multiple logs:

```elixir
ObservLib.Logs.with_context(%{request_id: "abc-123"}, fn ->
  ObservLib.Logs.info("Processing started")
  # ... work ...
  ObservLib.Logs.info("Processing complete")
end)
```

## Connecting to an OTLP Collector

To export telemetry data, configure an OTLP endpoint:

```elixir
config :observlib,
  service_name: "my_application",
  otlp_endpoint: "http://localhost:4318",
  resource_attributes: %{
    "service.version" => "1.0.0",
    "deployment.environment" => "production"
  }
```

### Running a Local Collector

Start an OpenTelemetry Collector with Docker:

```bash
docker run -p 4318:4318 otel/opentelemetry-collector:latest
```

Or use a `docker-compose.yml`:

```yaml
version: '3'
services:
  otel-collector:
    image: otel/opentelemetry-collector:latest
    ports:
      - "4318:4318"  # OTLP HTTP
```

### Viewing Data in Jaeger

For trace visualization, add Jaeger:

```yaml
version: '3'
services:
  jaeger:
    image: jaegertracing/all-in-one:latest
    ports:
      - "16686:16686"  # UI
      - "4318:4318"    # OTLP HTTP
```

Configure ObservLib to send traces:

```elixir
config :observlib,
  service_name: "my_application",
  otlp_endpoint: "http://localhost:4318"
```

View traces at http://localhost:16686

## Environment-Specific Configuration

Use `config/runtime.exs` for environment variables:

```elixir
import Config

config :observlib,
  service_name: System.get_env("SERVICE_NAME", "my_app"),
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),
  resource_attributes: %{
    "deployment.environment" => System.get_env("ENV", "development")
  }
```

## Next Steps

- [Configuration Guide](configuration.md) - All configuration options
- [Custom Instrumentation Guide](custom-instrumentation.md) - Advanced usage patterns
- [Example Scripts](../examples/) - Runnable code examples
