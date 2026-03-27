# Configuration

ObservLib is configured via application environment in your `config/*.exs` files.

## Basic Configuration

Minimal configuration requires only a service name:

```elixir
config :observlib,
  service_name: "my_service"
```

## Full Configuration Example

```elixir
config :observlib,
  # Required: Service identifier
  service_name: "my_service",

  # Optional: OTLP collector endpoint
  otlp_endpoint: "http://localhost:4318",

  # Optional: Additional resource attributes
  resource_attributes: %{
    "service.version" => "1.0.0",
    "deployment.environment" => "production",
    "service.namespace" => "payments"
  },

  # Optional: Pyroscope profiling endpoint
  pyroscope_endpoint: "http://localhost:4040",

  # Optional: Telemetry event prefixes to auto-instrument
  telemetry_events: [
    [:phoenix, :endpoint],
    [:phoenix, :router_dispatch],
    [:ecto, :repo, :query]
  ]
```

## Configuration Options Reference

### Required Options

| Option | Type | Description |
|--------|------|-------------|
| `service_name` | `String.t()` | Unique identifier for your service. Used in all telemetry data. |

### Optional Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `otlp_endpoint` | `String.t() \| nil` | `nil` | HTTP endpoint for OTLP collector. If nil, telemetry is collected but not exported. |
| `resource_attributes` | `map()` | `%{}` | Additional OpenTelemetry resource attributes attached to all signals. |
| `pyroscope_endpoint` | `String.t() \| nil` | `nil` | Pyroscope server endpoint for continuous profiling. |
| `telemetry_events` | `[event_prefix()]` | `[]` | List of telemetry event prefixes to automatically instrument. |

## Environment-Specific Configuration

Use `config/runtime.exs` for runtime environment variables:

```elixir
import Config

config :observlib,
  service_name: System.get_env("SERVICE_NAME", "my_app"),
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),
  resource_attributes: %{
    "deployment.environment" => System.get_env("ENV", "development"),
    "service.version" => System.get_env("APP_VERSION", "dev"),
    "host.name" => System.get_env("HOSTNAME", "localhost")
  }
```

## Per-Environment Configuration

### Development

```elixir
# config/dev.exs
import Config

config :observlib,
  service_name: "my_app_dev",
  otlp_endpoint: "http://localhost:4318",
  resource_attributes: %{
    "deployment.environment" => "development"
  }
```

### Test

```elixir
# config/test.exs
import Config

config :observlib,
  service_name: "my_app_test",
  otlp_endpoint: nil,  # Don't export in tests
  resource_attributes: %{
    "deployment.environment" => "test"
  }
```

### Production

```elixir
# config/prod.exs
import Config

config :observlib,
  service_name: "my_app",
  # Actual endpoint configured via runtime.exs
  resource_attributes: %{
    "deployment.environment" => "production"
  },
  telemetry_events: [
    [:phoenix, :endpoint],
    [:phoenix, :router_dispatch],
    [:ecto, :repo, :query]
  ]
```

## Runtime Configuration Access

Access configuration at runtime:

```elixir
# Get service name
ObservLib.service_name()
#=> "my_service"

# Get OTLP endpoint
ObservLib.otlp_endpoint()
#=> "http://localhost:4318"

# Get full resource attributes
ObservLib.resource()
#=> %{"service.name" => "my_service", "service.version" => "1.0.0", ...}
```

## Resource Attributes

Resource attributes follow [OpenTelemetry semantic conventions](https://opentelemetry.io/docs/specs/semconv/resource/).

Common resource attributes:

```elixir
resource_attributes: %{
  # Service attributes
  "service.version" => "1.2.3",
  "service.namespace" => "production",
  "service.instance.id" => "instance-001",

  # Deployment attributes
  "deployment.environment" => "production",

  # Host attributes
  "host.name" => "web-01.example.com",
  "host.id" => "i-1234567890abcdef0",

  # Cloud attributes (AWS example)
  "cloud.provider" => "aws",
  "cloud.region" => "us-east-1",
  "cloud.account.id" => "123456789012",

  # Container attributes
  "container.name" => "my-app-container",
  "container.id" => "abc123",
  "container.image.name" => "my-app",
  "container.image.tag" => "v1.2.3",

  # Kubernetes attributes
  "k8s.namespace.name" => "production",
  "k8s.pod.name" => "my-app-pod-xyz",
  "k8s.deployment.name" => "my-app"
}
```

## Next Steps

- [First Traces](first-traces.md) - Start tracing your application
- [Telemetry Integration](../guides/telemetry.md) - Auto-instrument Phoenix and Ecto
- [Production Configuration](../deployment/production-config.md) - Production best practices
