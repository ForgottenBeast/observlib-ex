# Custom Metrics Example
# Run with: mix run examples/custom_metrics.exs

IO.puts("=== Custom Metrics Examples ===\n")

Application.ensure_all_started(:observlib)

# -----------------------------------------------------------------------------
# 1. Counter Patterns
# -----------------------------------------------------------------------------
IO.puts("--- Counter Patterns ---")

# Simple counter
ObservLib.counter("events.total", 1)
IO.puts("Recorded simple counter")

# Counter with attributes for segmentation
ObservLib.counter("http.requests", 1, %{
  method: "GET",
  status: 200,
  path: "/api/users"
})

ObservLib.counter("http.requests", 1, %{
  method: "POST",
  status: 201,
  path: "/api/users"
})

ObservLib.counter("http.requests", 1, %{
  method: "GET",
  status: 404,
  path: "/api/users/123"
})
IO.puts("Recorded HTTP request counters with attributes")

# Batch counting
events = [
  %{type: "login", success: true},
  %{type: "login", success: false},
  %{type: "logout", success: true},
  %{type: "login", success: true}
]

Enum.each(events, fn event ->
  ObservLib.counter("auth.events", 1, %{
    type: event.type,
    success: event.success
  })
end)
IO.puts("Recorded batch of auth events")

IO.puts("")

# -----------------------------------------------------------------------------
# 2. Gauge Patterns
# -----------------------------------------------------------------------------
IO.puts("--- Gauge Patterns ---")

# System metrics
ObservLib.gauge("vm.memory.total", :erlang.memory(:total))
ObservLib.gauge("vm.memory.processes", :erlang.memory(:processes))
ObservLib.gauge("vm.memory.binary", :erlang.memory(:binary))
ObservLib.gauge("vm.memory.ets", :erlang.memory(:ets))
IO.puts("Recorded VM memory gauges")

# Process metrics
ObservLib.gauge("vm.process_count", :erlang.system_info(:process_count))
ObservLib.gauge("vm.port_count", :erlang.system_info(:port_count))
ObservLib.gauge("vm.atom_count", :erlang.system_info(:atom_count))
IO.puts("Recorded VM process/port/atom gauges")

# Scheduler utilization (would need actual measurement)
Enum.each(1..4, fn scheduler_id ->
  utilization = 50 + :rand.uniform(40)  # Simulated
  ObservLib.gauge("vm.scheduler.utilization", utilization, %{
    scheduler_id: scheduler_id
  })
end)
IO.puts("Recorded scheduler utilization gauges")

# Queue depths
queues = ["default", "high_priority", "background"]
Enum.each(queues, fn queue ->
  depth = :rand.uniform(100)
  ObservLib.gauge("queue.depth", depth, %{queue: queue})
end)
IO.puts("Recorded queue depth gauges")

IO.puts("")

# -----------------------------------------------------------------------------
# 3. Histogram Patterns
# -----------------------------------------------------------------------------
IO.puts("--- Histogram Patterns ---")

# Latency distributions
Enum.each(1..100, fn _ ->
  # Simulate varying latencies
  latency = :rand.normal(50, 15) |> max(1)
  ObservLib.histogram("http.request.duration_ms", latency, %{
    method: Enum.random(["GET", "POST", "PUT"]),
    endpoint: Enum.random(["/api/users", "/api/orders", "/api/products"])
  })
end)
IO.puts("Recorded 100 HTTP latency histogram observations")

# Size distributions
Enum.each(1..50, fn _ ->
  size = :rand.uniform(10000)
  ObservLib.histogram("http.response.size_bytes", size, %{
    content_type: Enum.random(["application/json", "text/html", "image/png"])
  })
end)
IO.puts("Recorded 50 response size histogram observations")

# Database query times
Enum.each(1..30, fn _ ->
  query_time = :rand.normal(10, 5) |> max(0.1)
  ObservLib.histogram("db.query.duration_ms", query_time, %{
    operation: Enum.random(["select", "insert", "update", "delete"]),
    table: Enum.random(["users", "orders", "products"])
  })
end)
IO.puts("Recorded 30 database query histogram observations")

IO.puts("")

# -----------------------------------------------------------------------------
# 4. Business Metrics Pattern
# -----------------------------------------------------------------------------
IO.puts("--- Business Metrics ---")

defmodule BusinessMetrics do
  @doc "Record an order being placed"
  def order_placed(order) do
    ObservLib.counter("orders.placed", 1, %{
      region: order.region,
      payment_method: order.payment_method
    })

    ObservLib.histogram("orders.value", order.total, %{
      region: order.region,
      currency: order.currency
    })

    ObservLib.histogram("orders.item_count", length(order.items), %{
      region: order.region
    })
  end

  @doc "Record user signup"
  def user_signup(user) do
    ObservLib.counter("users.signups", 1, %{
      source: user.signup_source,
      plan: user.plan
    })
  end

  @doc "Record feature usage"
  def feature_used(feature_name, user_tier) do
    ObservLib.counter("features.usage", 1, %{
      feature: feature_name,
      tier: user_tier
    })
  end
end

# Simulate business events
orders = [
  %{region: "us-west", payment_method: "card", total: 99.99, currency: "USD", items: [1, 2, 3]},
  %{region: "eu-west", payment_method: "paypal", total: 149.50, currency: "EUR", items: [1, 2]},
  %{region: "us-east", payment_method: "card", total: 29.99, currency: "USD", items: [1]}
]

Enum.each(orders, &BusinessMetrics.order_placed/1)
IO.puts("Recorded 3 business order metrics")

users = [
  %{signup_source: "organic", plan: "free"},
  %{signup_source: "referral", plan: "pro"},
  %{signup_source: "ads", plan: "free"}
]

Enum.each(users, &BusinessMetrics.user_signup/1)
IO.puts("Recorded 3 user signup metrics")

Enum.each(1..10, fn _ ->
  BusinessMetrics.feature_used(
    Enum.random(["export", "import", "share", "collaborate"]),
    Enum.random(["free", "pro", "enterprise"])
  )
end)
IO.puts("Recorded 10 feature usage metrics")

IO.puts("")

# -----------------------------------------------------------------------------
# 5. Periodic Metrics Collection
# -----------------------------------------------------------------------------
IO.puts("--- Periodic Metrics Pattern ---")
IO.puts("""
# Example GenServer for periodic metric collection:

defmodule MyApp.MetricsCollector do
  use GenServer

  @collection_interval 10_000  # 10 seconds

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_collection()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:collect, state) do
    collect_metrics()
    schedule_collection()
    {:noreply, state}
  end

  defp schedule_collection do
    Process.send_after(self(), :collect, @collection_interval)
  end

  defp collect_metrics do
    # VM metrics
    ObservLib.gauge("vm.memory.total", :erlang.memory(:total))
    ObservLib.gauge("vm.process_count", :erlang.system_info(:process_count))

    # Application-specific metrics
    collect_queue_metrics()
    collect_cache_metrics()
  end

  defp collect_queue_metrics do
    # Example: collect from your job queue
    # queue_stats = MyApp.JobQueue.stats()
    # ObservLib.gauge("jobs.pending", queue_stats.pending)
    # ObservLib.gauge("jobs.processing", queue_stats.processing)
  end

  defp collect_cache_metrics do
    # Example: collect from your cache
    # cache_stats = MyApp.Cache.stats()
    # ObservLib.gauge("cache.size", cache_stats.size)
    # ObservLib.gauge("cache.hit_rate", cache_stats.hit_rate)
  end
end
""")

# -----------------------------------------------------------------------------
# 6. Timing Helper Module
# -----------------------------------------------------------------------------
IO.puts("--- Timing Helper ---")

defmodule TimingHelper do
  @doc """
  Execute a function and record its duration as a histogram.
  """
  def timed(metric_name, attributes \\ %{}, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration_ms = System.monotonic_time() - start
                  |> System.convert_time_unit(:native, :millisecond)

    ObservLib.histogram(metric_name, duration_ms, attributes)
    result
  end

  @doc """
  Measure and record the size of a result.
  """
  def sized(metric_name, attributes \\ %{}, fun) do
    result = fun.()

    size = case result do
      binary when is_binary(binary) -> byte_size(binary)
      list when is_list(list) -> length(list)
      map when is_map(map) -> map_size(map)
      _ -> 0
    end

    ObservLib.histogram(metric_name, size, attributes)
    result
  end
end

# Usage examples
result = TimingHelper.timed("processing.duration_ms", %{type: "transform"}, fn ->
  Process.sleep(10)
  :ok
end)
IO.puts("Timed operation result: #{inspect(result)}")

data = TimingHelper.sized("response.items", %{endpoint: "/api/list"}, fn ->
  Enum.to_list(1..50)
end)
IO.puts("Sized operation returned #{length(data)} items")

IO.puts("")

# -----------------------------------------------------------------------------
# 7. SLA/SLO Tracking Pattern
# -----------------------------------------------------------------------------
IO.puts("--- SLA/SLO Tracking ---")
IO.puts("""
# Track SLA/SLO compliance with metrics:

defmodule MyApp.SLATracker do
  @latency_slo_ms 200  # 200ms latency SLO

  def track_request(duration_ms, attributes) do
    # Record the actual latency
    ObservLib.histogram("http.request.duration_ms", duration_ms, attributes)

    # Track SLO compliance
    if duration_ms <= @latency_slo_ms do
      ObservLib.counter("slo.latency.met", 1, attributes)
    else
      ObservLib.counter("slo.latency.violated", 1, attributes)
      ObservLib.Logs.warn("SLO violation", Map.merge(attributes, %{
        duration_ms: duration_ms,
        slo_ms: @latency_slo_ms
      }))
    end
  end
end

# Usage:
# MyApp.SLATracker.track_request(150, %{endpoint: "/api/users"})  # SLO met
# MyApp.SLATracker.track_request(350, %{endpoint: "/api/users"})  # SLO violated
""")

IO.puts("=== Custom Metrics Examples Complete ===")
IO.puts("""

Best practices:
1. Keep attribute cardinality low (avoid user IDs, request IDs in metrics)
2. Use counters for events, gauges for current values, histograms for distributions
3. Include units in metric names (duration_ms, size_bytes)
4. Use consistent attribute names across metrics
5. Collect periodic metrics in a dedicated GenServer
""")
