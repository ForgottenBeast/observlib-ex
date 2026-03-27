# Basic Usage Example
# Run with: mix run examples/basic_usage.exs

# Ensure ObservLib is started
Application.ensure_all_started(:observlib)

IO.puts("=== ObservLib Basic Usage Examples ===\n")

# -----------------------------------------------------------------------------
# 1. Traces
# -----------------------------------------------------------------------------
IO.puts("--- Traces ---")

# Simple traced operation
result = ObservLib.traced("example_operation", fn ->
  Process.sleep(10)
  {:ok, "completed"}
end)
IO.puts("Traced operation result: #{inspect(result)}")

# Traced operation with attributes
result = ObservLib.traced("database_query", %{"db.system" => "postgresql", "db.name" => "mydb"}, fn ->
  Process.sleep(5)
  [%{id: 1, name: "Alice"}, %{id: 2, name: "Bob"}]
end)
IO.puts("Query returned #{length(result)} rows")

# Manual span management
span = ObservLib.Traces.start_span("manual_span", %{"custom.attr" => "value"})
Process.sleep(5)
ObservLib.Traces.end_span(span)
IO.puts("Manual span completed")

# Nested spans
ObservLib.traced("parent_operation", fn ->
  ObservLib.traced("child_operation_1", fn ->
    Process.sleep(5)
  end)

  ObservLib.traced("child_operation_2", fn ->
    Process.sleep(5)
  end)
end)
IO.puts("Nested spans completed")

IO.puts("")

# -----------------------------------------------------------------------------
# 2. Metrics
# -----------------------------------------------------------------------------
IO.puts("--- Metrics ---")

# Counter - for counting events
ObservLib.counter("http.requests", 1, %{method: "GET", status: 200})
ObservLib.counter("http.requests", 1, %{method: "POST", status: 201})
ObservLib.counter("http.requests", 1, %{method: "GET", status: 404})
IO.puts("Recorded 3 HTTP request counters")

# Gauge - for current values
ObservLib.gauge("memory.usage_mb", :erlang.memory(:total) / 1_000_000)
ObservLib.gauge("process.count", length(Process.list()))
IO.puts("Recorded memory and process gauges")

# Histogram - for distributions
Enum.each(1..10, fn _ ->
  latency = :rand.uniform(100)
  ObservLib.histogram("http.request.duration_ms", latency, %{method: "GET"})
end)
IO.puts("Recorded 10 latency histogram observations")

IO.puts("")

# -----------------------------------------------------------------------------
# 3. Logs
# -----------------------------------------------------------------------------
IO.puts("--- Logs ---")

# Simple logs at different levels
ObservLib.Logs.debug("Debug message", module: "Example")
ObservLib.Logs.info("Info message", user_id: 123)
ObservLib.Logs.warn("Warning message", threshold: 80, current: 85)
ObservLib.Logs.error("Error message", error: "connection_timeout")
IO.puts("Emitted logs at all levels")

# Logs with context
ObservLib.Logs.with_context(%{request_id: "req-12345", user_id: 42}, fn ->
  ObservLib.Logs.info("Processing started")
  ObservLib.Logs.debug("Step 1 complete")
  ObservLib.Logs.info("Processing finished")
end)
IO.puts("Emitted logs with context")

IO.puts("")

# -----------------------------------------------------------------------------
# 4. Combined Usage
# -----------------------------------------------------------------------------
IO.puts("--- Combined Usage ---")

defmodule ExampleService do
  def process_request(request_id, user_id) do
    ObservLib.Logs.with_context(%{request_id: request_id, user_id: user_id}, fn ->
      ObservLib.traced("process_request", %{"request.id" => request_id}, fn ->
        ObservLib.Logs.info("Request received")
        ObservLib.counter("requests.received", 1)

        # Simulate processing steps
        result = validate_and_process(request_id)

        case result do
          {:ok, _} ->
            ObservLib.counter("requests.success", 1)
            ObservLib.Logs.info("Request completed successfully")

          {:error, reason} ->
            ObservLib.counter("requests.failed", 1, %{reason: reason})
            ObservLib.Logs.error("Request failed", reason: reason)
        end

        result
      end)
    end)
  end

  defp validate_and_process(request_id) do
    ObservLib.traced("validate", fn ->
      Process.sleep(5)
      ObservLib.Logs.debug("Validation passed")
      :ok
    end)

    ObservLib.traced("process", fn ->
      start = System.monotonic_time()
      Process.sleep(10 + :rand.uniform(20))
      duration = System.monotonic_time() - start
                 |> System.convert_time_unit(:native, :millisecond)

      ObservLib.histogram("processing.duration_ms", duration)
      {:ok, %{id: request_id, status: "processed"}}
    end)
  end
end

# Process a few requests
Enum.each(1..3, fn i ->
  request_id = "req-#{i}"
  user_id = 100 + i
  ExampleService.process_request(request_id, user_id)
end)

IO.puts("Processed 3 requests with full instrumentation")
IO.puts("")

# -----------------------------------------------------------------------------
# 5. Configuration Access
# -----------------------------------------------------------------------------
IO.puts("--- Configuration ---")

IO.puts("Service name: #{ObservLib.service_name()}")
IO.puts("OTLP endpoint: #{inspect(ObservLib.otlp_endpoint())}")
IO.puts("Resource: #{inspect(ObservLib.resource())}")

IO.puts("")
IO.puts("=== Examples Complete ===")
