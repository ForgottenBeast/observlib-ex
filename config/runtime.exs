import Config

# Runtime configuration (loaded at application start)
# Can override config with environment variables

if config_env() == :prod do
  config :observlib,
    service_name: System.get_env("OBSERVLIB_SERVICE_NAME") || "observlib",
    otlp_endpoint: System.get_env("OBSERVLIB_OTLP_ENDPOINT"),
    otlp_traces_endpoint: System.get_env("OBSERVLIB_OTLP_TRACES_ENDPOINT"),
    otlp_metrics_endpoint: System.get_env("OBSERVLIB_OTLP_METRICS_ENDPOINT"),
    otlp_logs_endpoint: System.get_env("OBSERVLIB_OTLP_LOGS_ENDPOINT"),
    otlp_timeout: String.to_integer(System.get_env("OBSERVLIB_OTLP_TIMEOUT") || "10000"),
    batch_size: String.to_integer(System.get_env("OBSERVLIB_BATCH_SIZE") || "512"),
    batch_timeout: String.to_integer(System.get_env("OBSERVLIB_BATCH_TIMEOUT") || "5000"),
    pyroscope_endpoint: System.get_env("OBSERVLIB_PYROSCOPE_ENDPOINT"),
    resource_attributes: %{
      "deployment.environment" => "production"
    }
end
