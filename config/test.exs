import Config

# Test-specific configuration
config :observlib,
  service_name: "observlib_test",
  log_level: :warning,
  resource_attributes: %{
    "deployment.environment" => "test"
  }
