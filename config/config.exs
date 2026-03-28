import Config

# Default configuration for ObservLib
config :observlib,
  service_name: "my_service",
  # General OTLP endpoint (used as fallback for all signal types)
  otlp_endpoint: nil,
  # Signal-specific OTLP endpoints (optional, override general endpoint)
  # otlp_traces_endpoint: "http://localhost:4318",
  # otlp_metrics_endpoint: "http://localhost:4318",
  # otlp_logs_endpoint: "http://localhost:4318",
  # OTLP exporter configuration
  otlp_headers: %{},
  otlp_timeout: 10000,
  batch_size: 512,
  batch_timeout: 5000,
  log_batch_limit: 1000,
  pyroscope_endpoint: nil,
  pyroscope_sample_rate: 5,
  log_level: :info,
  resource_attributes: %{},
  # Telemetry event prefixes to automatically attach handlers for
  # Example: [[:phoenix, :endpoint], [:ecto, :repo]]
  telemetry_events: [],
  # Cardinality limit per metric name to prevent unbounded ETS growth (sec-003)
  cardinality_limit: 2000,
  # Maximum active spans limit to prevent unbounded ETS growth (sec-013)
  max_active_spans: 10000,
  # Prometheus endpoint security configuration (sec-008)
  prometheus_max_connections: 10,
  prometheus_rate_limit: 100,
  # prometheus_basic_auth: {"username", "password"}
  prometheus_basic_auth: nil,
  # Attribute size limits to prevent resource exhaustion (sec-010)
  max_attribute_value_size: 4096,
  max_attribute_count: 128,
  # Sensitive attribute redaction (sec-011)
  # List of attribute key patterns to redact (case-insensitive substring match)
  # Set to [] to disable redaction
  redacted_attribute_keys: nil,
  # nil uses default list: ["password", "secret", "token", "authorization", etc.]
  # Pattern to replace redacted values with
  redaction_pattern: "[REDACTED]"

# Import environment-specific config
import_config "#{config_env()}.exs"
