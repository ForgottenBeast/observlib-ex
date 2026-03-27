# Configuration Guide

This guide covers all ObservLib configuration options.

## Configuration File

Add configuration to `config/config.exs` or environment-specific files:

```elixir
config :observlib,
  service_name: "my_service",
  otlp_endpoint: "http://localhost:4318"
```

## All Configuration Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `service_name` | string | **required** | Service name for telemetry identification |
| `otlp_endpoint` | string | `nil` | OTLP collector HTTP endpoint |
| `otlp_traces_endpoint` | string | `otlp_endpoint` | Traces-specific endpoint |
| `otlp_metrics_endpoint` | string | `otlp_endpoint` | Metrics-specific endpoint |
| `otlp_logs_endpoint` | string | `otlp_endpoint` | Logs-specific endpoint |
| `otlp_headers` | map | `%{}` | HTTP headers for OTLP requests |
| `otlp_timeout` | integer | `10000` | Request timeout in milliseconds |
| `batch_size` | integer | `512` | Batch size for exporters |
| `batch_timeout` | integer | `5000` | Batch flush timeout in milliseconds |
| `pyroscope_endpoint` | string | `nil` | Pyroscope profiling endpoint |
| `resource_attributes` | map | `%{}` | Additional resource attributes |
| `telemetry_events` | list | `[]` | Telemetry event prefixes to instrument |

## Minimal Configuration

```elixir
config :observlib,
  service_name: "my_service"
```

## Full Configuration Example

```elixir
config :observlib,
  # Required
  service_name: "api_server",

  # OTLP endpoints
  otlp_endpoint: "http://otel-collector:4318",
  otlp_traces_endpoint: "http://traces-backend:4318",
  otlp_metrics_endpoint: "http://metrics-backend:4318",
  otlp_logs_endpoint: "http://logs-backend:4318",

  # OTLP settings
  otlp_headers: %{
    "Authorization" => "Bearer token123"
  },
  otlp_timeout: 15000,
  batch_size: 256,
  batch_timeout: 3000,

  # Pyroscope profiling
  pyroscope_endpoint: "http://pyroscope:4040",

  # Resource attributes
  resource_attributes: %{
    "service.version" => "1.0.0",
    "deployment.environment" => "production",
    "service.namespace" => "platform"
  },

  # Telemetry event instrumentation
  telemetry_events: [
    [:phoenix, :endpoint],
    [:ecto, :repo],
    [:my_app, :custom]
  ]
```

## Environment-Specific Configuration

### Development (`config/dev.exs`)

```elixir
config :observlib,
  service_name: "my_service_dev",
  resource_attributes: %{
    "deployment.environment" => "development"
  }
```

### Production (`config/prod.exs`)

```elixir
config :observlib,
  service_name: "my_service",
  otlp_endpoint: "http://otel-collector:4318",
  resource_attributes: %{
    "deployment.environment" => "production"
  }
```

### Test (`config/test.exs`)

```elixir
config :observlib,
  service_name: "my_service_test",
  resource_attributes: %{
    "deployment.environment" => "test"
  }
```

## Runtime Configuration

Use `config/runtime.exs` for environment variables:

```elixir
import Config

config :observlib,
  service_name: System.get_env("SERVICE_NAME") || raise("SERVICE_NAME required"),
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),
  pyroscope_endpoint: System.get_env("PYROSCOPE_ENDPOINT"),
  resource_attributes: %{
    "service.version" => System.get_env("APP_VERSION", "unknown"),
    "deployment.environment" => System.get_env("ENV", "development"),
    "host.name" => System.get_env("HOSTNAME", node() |> to_string())
  }
```

## OTLP Endpoint Configuration

### Single Collector

Send all signals to one collector:

```elixir
config :observlib,
  otlp_endpoint: "http://otel-collector:4318"
```

### Separate Backends

Route signals to different backends:

```elixir
config :observlib,
  otlp_traces_endpoint: "http://jaeger:4318",
  otlp_metrics_endpoint: "http://prometheus-receiver:4318",
  otlp_logs_endpoint: "http://loki:4318"
```

### Authenticated Endpoints

Add authorization headers:

```elixir
config :observlib,
  otlp_endpoint: "https://api.vendor.com/v1/otlp",
  otlp_headers: %{
    "Authorization" => "Bearer #{System.get_env("OTLP_API_KEY")}",
    "X-Custom-Header" => "value"
  }
```

## Prometheus Configuration

ObservLib exposes metrics via OTLP. To scrape with Prometheus, use an OpenTelemetry Collector with Prometheus exporter:

```yaml
# otel-collector-config.yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318

exporters:
  prometheus:
    endpoint: 0.0.0.0:9090

service:
  pipelines:
    metrics:
      receivers: [otlp]
      exporters: [prometheus]
```

## Pyroscope Configuration

Enable continuous profiling:

```elixir
config :observlib,
  pyroscope_endpoint: "http://pyroscope:4040",
  resource_attributes: %{
    "service.name" => "my_service"
  }
```

## Telemetry Events Configuration

Automatically instrument library events:

```elixir
config :observlib,
  telemetry_events: [
    # Phoenix
    [:phoenix, :endpoint],
    [:phoenix, :router_dispatch],

    # Ecto
    [:ecto, :repo],

    # Custom application events
    [:my_app, :worker],
    [:my_app, :cache]
  ]
```

## Accessing Configuration at Runtime

```elixir
# Get service name
ObservLib.service_name()
#=> "my_service"

# Get resource attributes
ObservLib.resource()
#=> %{"service.name" => "my_service", "service.version" => "1.0.0", ...}

# Get OTLP endpoint
ObservLib.otlp_endpoint()
#=> "http://otel-collector:4318"

# Get Pyroscope endpoint
ObservLib.pyroscope_endpoint()
#=> "http://pyroscope:4040"
```

## Validation

ObservLib validates configuration on startup:

- `service_name` must be a non-empty string
- If validation fails, the application will not start

```elixir
# This will raise an error:
config :observlib,
  service_name: ""  # ArgumentError: service_name must be a non-empty string
```
