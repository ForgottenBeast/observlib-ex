# Quick Start

This guide will have you instrumenting your first Elixir application in under 5 minutes.

## Minimal Configuration

Add to `config/config.exs`:

```elixir
config :observlib,
  service_name: "my_application"
```

That's it! ObservLib is now active and collecting telemetry.

## Your First Trace

Create a traced function:

```elixir
defmodule MyApp.Example do
  def process_request(user_id) do
    ObservLib.traced("process_request", %{"user.id" => user_id}, fn ->
      # Your business logic here
      {:ok, "processed"}
    end)
  end
end
```

Call it:

```elixir
iex> MyApp.Example.process_request(123)
{:ok, "processed"}
```

A span named "process_request" with attribute `user.id=123` was created!

## Your First Metric

Record a counter:

```elixir
ObservLib.counter("requests.processed", 1, %{status: "success"})
```

Record request duration:

```elixir
start_time = System.monotonic_time()
# ... do work ...
duration = System.monotonic_time() - start_time |> System.convert_time_unit(:native, :millisecond)

ObservLib.histogram("request.duration_ms", duration, %{endpoint: "/users"})
```

## Your First Log

Emit a structured log:

```elixir
ObservLib.Logs.info("User authenticated", user_id: 123, method: "oauth")
```

Logs automatically include trace context when executed within a span!

## Viewing Your Data

To actually see your telemetry data, configure an OTLP endpoint:

```elixir
config :observlib,
  service_name: "my_application",
  otlp_endpoint: "http://localhost:4318"
```

Then start a local collector:

```bash
docker run -p 4318:4318 -p 16686:16686 jaegertracing/all-in-one:latest
```

Visit http://localhost:16686 to see your traces in Jaeger!

## Complete Example

Here's a full example combining traces, metrics, and logs:

```elixir
defmodule MyApp.Orders do
  require ObservLib.Logs

  def create_order(user_id, items) do
    ObservLib.traced("create_order", %{"user.id" => user_id}, fn ->
      ObservLib.Logs.info("Creating order",
        user_id: user_id,
        item_count: length(items)
      )

      result = case save_to_db(items) do
        {:ok, order} ->
          ObservLib.counter("orders.created", 1, %{status: "success"})
          ObservLib.gauge("orders.total_value", order.total)
          {:ok, order}

        {:error, reason} ->
          ObservLib.counter("orders.created", 1, %{status: "error"})
          ObservLib.Logs.error("Order creation failed",
            user_id: user_id,
            reason: reason
          )
          {:error, reason}
      end

      result
    end)
  end

  defp save_to_db(items) do
    # Your DB logic here
    {:ok, %{id: 1, total: 99.99}}
  end
end
```

## Next Steps

- [Configuration](configuration.md) - Learn about all configuration options
- [First Traces](first-traces.md) - Deep dive into distributed tracing
- [First Metrics](first-metrics.md) - Learn about counters, gauges, and histograms
- [First Logs](first-logs.md) - Structured logging with context
