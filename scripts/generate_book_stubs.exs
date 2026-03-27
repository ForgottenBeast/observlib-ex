#!/usr/bin/env elixir

# Script to generate stub files for mdBook pages that don't exist yet
# Run with: mix run scripts/generate_book_stubs.exs

defmodule BookStubGenerator do
  @stub_template """
  # <%= title %>

  > **Note:** This page is under construction. Check back soon!

  <%= description %>

  ## Topics Covered

  <%= topics %>

  ## Related Documentation

  <%= related %>

  ## API Reference

  For detailed API documentation, see the [HexDocs](https://hexdocs.pm/observlib).
  """

  @stubs %{
    "getting-started/first-traces.md" => %{
      title: "First Traces",
      description: "Learn how to create and manage distributed traces in your Elixir application.",
      topics: """
      - Creating spans manually
      - Using the `traced/2` helper
      - Adding attributes to spans
      - Nested spans and parent-child relationships
      - Span events and exceptions
      """,
      related: """
      - [Distributed Tracing Guide](../guides/tracing.md)
      - [Context Propagation](../concepts/context-propagation.md)
      - [ObservLib.Traces API](https://hexdocs.pm/observlib/ObservLib.Traces.html)
      """
    },
    "getting-started/first-metrics.md" => %{
      title: "First Metrics",
      description: "Learn how to record and export metrics from your Elixir application.",
      topics: """
      - Counters for event counting
      - Gauges for point-in-time values
      - Histograms for distributions
      - Metric labels and cardinality
      - Prometheus export
      """,
      related: """
      - [Metrics Collection Guide](../guides/metrics.md)
      - [Prometheus Integration](../integrations/prometheus.md)
      - [ObservLib.Metrics API](https://hexdocs.pm/observlib/ObservLib.Metrics.html)
      """
    },
    "getting-started/first-logs.md" => %{
      title: "First Logs",
      description: "Learn how to emit structured logs with automatic trace correlation.",
      topics: """
      - Structured logging basics
      - Log levels (debug, info, warn, error)
      - Automatic trace context injection
      - Log context management
      - Integration with Elixir Logger
      """,
      related: """
      - [Structured Logging Guide](../guides/logging.md)
      - [ObservLib.Logs API](https://hexdocs.pm/observlib/ObservLib.Logs.html)
      """
    },
    "concepts/opentelemetry.md" => %{
      title: "OpenTelemetry Primer",
      description: "An introduction to OpenTelemetry concepts and how they're implemented in ObservLib.",
      topics: """
      - What is OpenTelemetry?
      - Traces, metrics, and logs
      - W3C Trace Context
      - Semantic conventions
      - OTLP protocol
      """,
      related: """
      - [OpenTelemetry.io](https://opentelemetry.io)
      - [Architecture Overview](architecture.md)
      """
    },
    "concepts/supervision.md" => %{
      title: "Supervision Trees",
      description: "How ObservLib uses OTP supervision for reliability.",
      topics: """
      - OTP supervision strategies
      - One-for-one vs rest-for-one
      - Fault isolation
      - Process restart semantics
      - Error recovery
      """,
      related: """
      - [Architecture Overview](architecture.md)
      - [Elixir Supervisor docs](https://hexdocs.pm/elixir/Supervisor.html)
      """
    },
    "concepts/context-propagation.md" => %{
      title: "Context Propagation",
      description: "How trace context flows across processes, nodes, and services.",
      topics: """
      - Process-level context
      - Cross-process propagation
      - W3C Trace Context headers
      - Distributed tracing
      - Context injection and extraction
      """,
      related: """
      - [Distributed Tracing Guide](../guides/tracing.md)
      - [Phoenix Integration](../integrations/phoenix.md)
      """
    },
    "guides/tracing.md" => %{
      title: "Distributed Tracing",
      description: "Comprehensive guide to distributed tracing with ObservLib.",
      topics: """
      - Span lifecycle
      - Manual span management
      - Automatic instrumentation
      - Context propagation
      - Span attributes and events
      - Error recording
      """,
      related: """
      - [ObservLib.Traces API](https://hexdocs.pm/observlib/ObservLib.Traces.html)
      - [Compile-time Instrumentation](traced-macro.md)
      """
    },
    "guides/metrics.md" => %{
      title: "Metrics Collection",
      description: "Comprehensive guide to metrics collection with ObservLib.",
      topics: """
      - Metric types (counter, gauge, histogram)
      - Choosing the right metric type
      - Label best practices
      - Cardinality management
      - Aggregation and export
      """,
      related: """
      - [ObservLib.Metrics API](https://hexdocs.pm/observlib/ObservLib.Metrics.html)
      - [Prometheus Integration](../integrations/prometheus.md)
      """
    },
    "guides/logging.md" => %{
      title: "Structured Logging",
      description: "Comprehensive guide to structured logging with ObservLib.",
      topics: """
      - Log levels and semantics
      - Structured vs unstructured logs
      - Trace context correlation
      - Log context management
      - Performance considerations
      """,
      related: """
      - [ObservLib.Logs API](https://hexdocs.pm/observlib/ObservLib.Logs.html)
      - [Elixir Logger](https://hexdocs.pm/logger/Logger.html)
      """
    },
    "guides/telemetry.md" => %{
      title: "Telemetry Integration",
      description: "Automatic instrumentation via Erlang :telemetry.",
      topics: """
      - Telemetry event handlers
      - Phoenix instrumentation
      - Ecto query instrumentation
      - Custom telemetry events
      - Event filtering
      """,
      related: """
      - [ObservLib.Telemetry API](https://hexdocs.pm/observlib/ObservLib.Telemetry.html)
      - [Phoenix Integration](../integrations/phoenix.md)
      - [Ecto Integration](../integrations/ecto.md)
      """
    },
    "guides/traced-macro.md" => %{
      title: "Compile-time Instrumentation",
      description: "Using the @traced macro for zero-overhead instrumentation.",
      topics: """
      - How @traced works
      - Macro vs runtime instrumentation
      - Attribute configuration
      - Performance characteristics
      - Best practices
      """,
      related: """
      - [ObservLib.Traced API](https://hexdocs.pm/observlib/ObservLib.Traced.html)
      - [Custom Instrumentation](custom-instrumentation.md)
      """
    },
    "integrations/ecto.md" => %{
      title: "Ecto Database Integration",
      description: "Instrumenting Ecto queries with ObservLib.",
      topics: """
      - Telemetry handler setup
      - Query instrumentation
      - Connection pool metrics
      - Transaction tracing
      - Performance tips
      """,
      related: """
      - [Telemetry Integration](../guides/telemetry.md)
      - [Example: examples/ecto_integration.exs](../../examples/ecto_integration.exs)
      """
    },
    "integrations/otlp-exporters.md" => %{
      title: "OTLP Exporters",
      description: "Exporting telemetry via OTLP protocol.",
      topics: """
      - OTLP/HTTP protocol
      - Batch configuration
      - Retry logic
      - Compression
      - Authentication
      """,
      related: """
      - [Configuration](../getting-started/configuration.md)
      - [OTLP Specification](https://opentelemetry.io/docs/specs/otlp/)
      """
    },
    "integrations/prometheus.md" => %{
      title: "Prometheus Integration",
      description: "Exposing metrics in Prometheus format.",
      topics: """
      - Prometheus exposition format
      - Scrape endpoint (:9568)
      - Metric mapping
      - Label conversion
      - Performance
      """,
      related: """
      - [Metrics Guide](../guides/metrics.md)
      - [ObservLib.Metrics.PrometheusReader API](https://hexdocs.pm/observlib/ObservLib.Metrics.PrometheusReader.html)
      """
    },
    "deployment/production-config.md" => %{
      title: "Production Configuration",
      description: "Best practices for production deployments.",
      topics: """
      - Environment variables
      - Resource attributes
      - Sampling strategies
      - Export batch sizes
      - Security considerations
      """,
      related: """
      - [Configuration](../getting-started/configuration.md)
      - [Observability Stack](observability-stack.md)
      """
    },
    "deployment/observability-stack.md" => %{
      title: "Observability Stack",
      description: "Setting up a complete observability infrastructure.",
      topics: """
      - OpenTelemetry Collector
      - Jaeger for traces
      - Prometheus for metrics
      - Grafana for visualization
      - Loki for logs
      - Docker Compose example
      """,
      related: """
      - [Production Configuration](production-config.md)
      - [OTLP Exporters](../integrations/otlp-exporters.md)
      """
    },
    "deployment/performance.md" => %{
      title: "Performance Tuning",
      description: "Optimizing ObservLib for high-throughput applications.",
      topics: """
      - Overhead measurements
      - Sampling strategies
      - Batch configuration
      - Memory management
      - Profiling
      """,
      related: """
      - [Architecture Overview](../concepts/architecture.md)
      - [Continuous Profiling](../integrations/pyroscope.md)
      """
    },
    "deployment/troubleshooting.md" => %{
      title: "Troubleshooting",
      description: "Common issues and solutions.",
      topics: """
      - Export failures
      - Missing traces
      - High cardinality metrics
      - Performance degradation
      - Debug logging
      """,
      related: """
      - [Performance Tuning](performance.md)
      - [Configuration Reference](../appendix/config-reference.md)
      """
    },
    "appendix/config-reference.md" => %{
      title: "Configuration Reference",
      description: "Complete reference of all configuration options.",
      topics: """
      - All config keys
      - Default values
      - Type specifications
      - Environment variable mapping
      """,
      related: """
      - [Configuration](../getting-started/configuration.md)
      - [Production Configuration](../deployment/production-config.md)
      """
    },
    "appendix/examples.md" => %{
      title: "Examples",
      description: "Links to runnable example scripts.",
      topics: """
      - Basic usage
      - Phoenix integration
      - Ecto integration
      - Custom metrics
      - Full pipeline tests
      """,
      related: """
      - [examples/ directory](../../examples/)
      """
    },
    "appendix/glossary.md" => %{
      title: "Glossary",
      description: "Definitions of key terms.",
      topics: """
      - OpenTelemetry terms
      - ObservLib-specific terms
      - Observability concepts
      """,
      related: """
      - [OpenTelemetry Primer](../concepts/opentelemetry.md)
      """
    },
    "appendix/contributing.md" => %{
      title: "Contributing",
      description: "How to contribute to ObservLib.",
      topics: """
      - Development setup
      - Running tests
      - Code style
      - Pull request process
      - Issue guidelines
      """,
      related: """
      - [GitHub Repository](https://github.com/yourorg/observlib)
      """
    },
    "appendix/changelog.md" => %{
      title: "Changelog",
      description: "Version history and changes.",
      topics: """
      - Version 0.1.0 - Initial release
      """,
      related: """
      - [CHANGELOG.md](../../CHANGELOG.md)
      """
    }
  }

  def run do
    IO.puts("Generating book stub files...")

    Enum.each(@stubs, fn {path, data} ->
      full_path = Path.join("docs/book", path)
      dir = Path.dirname(full_path)

      # Create directory if needed
      File.mkdir_p!(dir)

      # Generate content from template
      content = EEx.eval_string(@stub_template,
        title: data.title,
        description: data.description,
        topics: data.topics,
        related: data.related
      )

      # Write file
      File.write!(full_path, content)
      IO.puts("  ✓ #{path}")
    end)

    IO.puts("\n✓ Generated #{map_size(@stubs)} stub files")
    IO.puts("\nNext steps:")
    IO.puts("  1. Review generated stubs")
    IO.puts("  2. Fill in content for priority pages")
    IO.puts("  3. Run: mdbook build")
  end
end

BookStubGenerator.run()
