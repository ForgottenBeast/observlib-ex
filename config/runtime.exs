import Config

# Runtime configuration (loaded at application start)
# Can override config with environment variables

# Helper function to safely parse environment variable integers
parse_env_integer = fn env_var, default_value ->
  case System.get_env(env_var) do
    nil ->
      default_value

    "" ->
      default_value

    value ->
      case Integer.parse(value) do
        {timeout, _} when timeout > 0 ->
          timeout

        _ ->
          IO.warn("Invalid #{env_var}: #{inspect(value)}, using default #{default_value}ms")
          default_value
      end
  end
end

if config_env() == :prod do
  config :observlib,
    service_name: System.get_env("OBSERVLIB_SERVICE_NAME") || "observlib",
    otlp_endpoint: System.get_env("OBSERVLIB_OTLP_ENDPOINT"),
    otlp_traces_endpoint: System.get_env("OBSERVLIB_OTLP_TRACES_ENDPOINT"),
    otlp_metrics_endpoint: System.get_env("OBSERVLIB_OTLP_METRICS_ENDPOINT"),
    otlp_logs_endpoint: System.get_env("OBSERVLIB_OTLP_LOGS_ENDPOINT"),
    otlp_timeout: parse_env_integer.("OBSERVLIB_OTLP_TIMEOUT", 10_000),
    batch_size: parse_env_integer.("OBSERVLIB_BATCH_SIZE", 512),
    batch_timeout: parse_env_integer.("OBSERVLIB_BATCH_TIMEOUT", 5_000),
    pyroscope_endpoint: System.get_env("OBSERVLIB_PYROSCOPE_ENDPOINT"),
    resource_attributes: %{
      "deployment.environment" => "production"
    }
end
