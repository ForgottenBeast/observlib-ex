import Config

# Development-specific configuration
config :observlib,
  service_name: "observlib_dev",
  log_level: :debug,
  resource_attributes: %{
    "deployment.environment" => "development"
  }
