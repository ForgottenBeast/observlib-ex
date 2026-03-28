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

## Security Configuration

ObservLib includes comprehensive security features enabled by default. This section covers security-related configuration options.

### TLS/SSL Configuration

**Default: TLS verification enabled for HTTPS**

```elixir
config :observlib,
  # TLS verification (enabled by default)
  tls_verify: true,

  # TLS versions (default: TLS 1.2 and 1.3)
  tls_versions: [:"tlsv1.3", :"tlsv1.2"],

  # Custom CA certificate file (optional)
  tls_ca_cert_file: "/etc/ssl/certs/corporate-ca.pem"
```

**Security Warning**: TLS 1.0 and 1.1 are not supported due to known vulnerabilities. Always use HTTPS in production environments.

**Development vs Production**:
```elixir
# Development (localhost)
config :observlib,
  otlp_endpoint: "http://localhost:4318"  # OK for localhost

# Production (remote hosts)
config :observlib,
  otlp_endpoint: "https://collector.prod.example.com:4318"  # Always use HTTPS
```

ObservLib will log a warning if you use plaintext HTTP to a remote host.

### Resource Limits

Prevent resource exhaustion attacks with configurable limits:

```elixir
config :observlib,
  # Metric cardinality limit (default: 2000)
  # Maximum unique attribute combinations per metric name
  cardinality_limit: 2000,

  # Attribute count limit (default: 128)
  # Maximum number of attributes per span/metric/log
  max_attribute_count: 128,

  # Attribute value size limit (default: 4096 bytes)
  # Maximum size of individual attribute values
  max_attribute_value_size: 4096,

  # Log batch limit (default: 1000)
  # Maximum queued logs when collector is unavailable
  log_batch_limit: 1000
```

**Why these limits matter**:
- Prevents memory exhaustion from high-cardinality metrics
- Protects against oversized attribute values
- Prevents CPU exhaustion from processing excessive attributes
- Limits memory growth during collector outages

### Sensitive Data Redaction

Automatically redact sensitive attribute keys:

```elixir
config :observlib,
  # Redacted attribute keys (default: predefined list)
  redacted_attribute_keys: [
    "password", "passwd", "secret", "token",
    "authorization", "auth", "bearer",
    "api_key", "apikey", "access_key", "private_key",
    "credit_card", "creditcard", "card_number", "cvv",
    "ssn", "social_security", "session"
  ],

  # Redaction pattern (default: "[REDACTED]")
  redaction_pattern: "[REDACTED]"
```

**Default redaction is enabled automatically**. Add custom patterns to the list as needed:

```elixir
config :observlib,
  redacted_attribute_keys: [
    "password", "token", "api_key",
    "customer_ssn",    # Custom
    "internal_id"      # Custom
  ]
```

### Prometheus Endpoint Security

Secure the Prometheus metrics endpoint:

```elixir
config :observlib,
  # HTTP Basic Authentication (default: nil)
  prometheus_basic_auth: {"username", "strong_password"},

  # Rate limiting (default: 100 requests per minute)
  prometheus_rate_limit: 100,

  # Connection limiting (default: 10 concurrent connections)
  prometheus_max_connections: 10,

  # Custom port (default: 9568)
  prometheus_port: 9568
```

**Security Best Practices**:
- Always enable `prometheus_basic_auth` in production
- Use strong passwords (12+ characters)
- Store credentials in environment variables, not in code
- Deploy behind a firewall or TLS-terminating proxy

**Example with environment variables**:
```elixir
# config/runtime.exs
config :observlib,
  prometheus_basic_auth: {
    System.get_env("PROMETHEUS_USER"),
    System.get_env("PROMETHEUS_PASSWORD")
  }
```

### Complete Security Configuration

Recommended production configuration with all security features:

```elixir
# config/prod.exs
config :observlib,
  # Required
  service_name: "my_service",

  # HTTPS with TLS verification
  otlp_endpoint: "https://collector.prod.example.com:4318",
  tls_verify: true,
  tls_versions: [:"tlsv1.3", :"tlsv1.2"],

  # Optional: Custom CA certificate
  # tls_ca_cert_file: "/etc/ssl/certs/corporate-ca.pem",

  # Resource limits
  cardinality_limit: 2000,
  max_attribute_count: 128,
  max_attribute_value_size: 4096,
  log_batch_limit: 1000,

  # Prometheus security
  prometheus_basic_auth: {
    System.get_env("PROMETHEUS_USER"),
    System.get_env("PROMETHEUS_PASSWORD")
  },
  prometheus_rate_limit: 100,
  prometheus_max_connections: 10,

  # Sensitive data redaction (enabled by default)
  redacted_attribute_keys: [
    "password", "token", "api_key", "secret",
    # Add custom patterns as needed
  ],

  # Batch processing
  batch_size: 512,
  batch_timeout: 5000
```

### Security Configuration Table

| Option | Default | Security Impact |
|--------|---------|----------------|
| `tls_verify` | `true` | Prevents man-in-the-middle attacks |
| `tls_versions` | `[:"tlsv1.3", :"tlsv1.2"]` | Uses only secure TLS versions |
| `cardinality_limit` | `2000` | Prevents memory exhaustion |
| `max_attribute_count` | `128` | Prevents CPU exhaustion |
| `max_attribute_value_size` | `4096` | Prevents memory attacks |
| `log_batch_limit` | `1000` | Prevents unbounded queue growth |
| `prometheus_basic_auth` | `nil` | Controls access to metrics endpoint |
| `prometheus_rate_limit` | `100` | Prevents denial-of-service |
| `prometheus_max_connections` | `10` | Prevents connection exhaustion |
| `redacted_attribute_keys` | (18 patterns) | Prevents credential leakage |

### Security Warnings

ObservLib logs warnings for insecure configurations:

```
# Plaintext HTTP to remote host
[warning] Plaintext HTTP connection to remote host: collector.example.com

# Attribute truncation
[warning] Attribute value truncated (original_size: 10000, truncated_size: 4096)

# Cardinality limit exceeded
[warning] Cardinality limit exceeded (name: "http.requests", limit: 2000)

# Rate limiting
[warning] Prometheus rate limit exceeded

# Connection limit
[warning] Prometheus connection limit exceeded (active: 10, max: 10)
```

Monitor these warnings in production for potential security issues.

### Additional Security Resources

For comprehensive security information, see:

- [SECURITY.md](../SECURITY.md) - Security disclosure policy and vulnerability reporting
- [Security Overview](../docs/book/security/overview.md) - Security architecture and features
- [Security Configuration Guide](../docs/book/security/configuration.md) - Detailed configuration examples
- [Security Best Practices](../docs/book/security/best-practices.md) - Production deployment checklist
- [Threat Model](../docs/book/security/threat-model.md) - Attack vectors and mitigations
