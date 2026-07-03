import Config

# Test-specific configuration
config :observlib,
  service_name: "observlib_test",
  # Logs children are endpoint-gated (no-op mode without one); tests exercise
  # the exporter/backend against Bypass, so boot them with a logs endpoint.
  # Deliberately NOT :otlp_endpoint — that would also wake metrics/traces
  # exporters and change unrelated test behavior.
  otlp_logs_endpoint: "http://localhost:4318",
  log_level: :warning,
  prometheus_rate_limit: 10_000,
  cardinality_limit: 10,
  resource_attributes: %{
    "deployment.environment" => "test"
  }
