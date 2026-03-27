# Introduction

Welcome to **ObservLib**, a comprehensive OpenTelemetry observability library for Elixir applications.

## What is ObservLib?

ObservLib provides a unified interface for:

- **Distributed Tracing** - Track requests across services with automatic context propagation
- **Metrics Collection** - Counters, gauges, and histograms with OTLP and Prometheus export
- **Structured Logging** - Contextual logs with automatic trace correlation
- **Continuous Profiling** - Integration with Pyroscope for production profiling
- **Automatic Instrumentation** - Telemetry integration for Phoenix, Ecto, and more

## Why ObservLib?

### Built for Elixir/OTP

ObservLib is designed from the ground up for Elixir's concurrency model:

- **Supervision Trees** - Proper OTP supervision for all components
- **ETS-backed Storage** - Cross-process data access without message passing overhead
- **Process Dictionary Free** - No hidden state, all data in managed GenServers
- **Zero Runtime Overhead** - Compile-time instrumentation with the `@traced` macro

### OpenTelemetry Native

Full compliance with OpenTelemetry specifications:

- OTLP/HTTP export for traces, metrics, and logs
- W3C Trace Context propagation
- Semantic conventions for attributes
- Compatible with Jaeger, Grafana, Prometheus, and more

### Production Ready

Built for reliability:

- Comprehensive test coverage (25 test suites)
- Integration tests with mock OTLP server
- Proper error handling and graceful degradation
- Minimal dependencies

## Quick Example

```elixir
# Add to config/config.exs
config :observlib,
  service_name: "my_service",
  otlp_endpoint: "http://localhost:4318"

# Instrument your code
defmodule MyApp.Users do
  use ObservLib.Traced

  @traced attributes: %{"operation" => "db.query"}
  def get_user(id) do
    ObservLib.Logs.info("Fetching user", user_id: id)
    user = Repo.get(User, id)
    ObservLib.counter("users.fetched", 1, %{found: user != nil})
    user
  end
end
```

This single instrumented function:
- Creates a span named "MyApp.Users.get_user"
- Emits a structured log with trace context
- Records a counter metric
- Exports everything via OTLP

## Documentation Structure

This book is organized into sections:

- **Getting Started** - Installation, configuration, and first steps
- **Core Concepts** - Architecture and key concepts
- **Usage Guides** - Deep dives into traces, metrics, logs, and instrumentation
- **Integrations** - Phoenix, Ecto, Pyroscope, and exporters
- **Deployment** - Production configuration and observability stack setup

For detailed API documentation, see [HexDocs](https://hexdocs.pm/observlib).

## Next Steps

Ready to get started? Head to [Installation](getting-started/installation.md) to add ObservLib to your project.
