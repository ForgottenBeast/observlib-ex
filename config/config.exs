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
  pyroscope_endpoint: nil,
  pyroscope_sample_rate: 5,
  log_level: :info,
  resource_attributes: %{}

# Import environment-specific config
import_config "#{config_env()}.exs"
