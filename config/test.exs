import Config

# Test-specific configuration
config :observlib,
  service_name: "observlib_test",
  log_level: :warning,
  prometheus_rate_limit: 10_000,
  resource_attributes: %{
    "deployment.environment" => "test"
  }
