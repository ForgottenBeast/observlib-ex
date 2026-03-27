# Ecto Integration Example
#
# This example shows how to integrate ObservLib with Ecto for database
# query instrumentation.

IO.puts("=== Ecto Integration Patterns ===\n")

# -----------------------------------------------------------------------------
# 1. Telemetry Event Handler for Ecto
# -----------------------------------------------------------------------------
IO.puts("--- 1. Ecto Telemetry Handler ---")
IO.puts("""
# Create lib/my_app/ecto_telemetry.ex:

defmodule MyApp.EctoTelemetry do
  @moduledoc \"\"\"
  Telemetry handler for Ecto query instrumentation.
  \"\"\"

  require Logger

  @doc \"\"\"
  Attach handlers for Ecto telemetry events.
  Call this from your application startup.
  \"\"\"
  def setup do
    events = [
      [:my_app, :repo, :query]
    ]

    :telemetry.attach_many(
      "my-app-ecto-handler",
      events,
      &__MODULE__.handle_event/4,
      %{}
    )
  end

  def handle_event([:my_app, :repo, :query], measurements, metadata, _config) do
    # Extract timing information
    total_time_ms = measurements[:total_time] |> native_to_ms()
    decode_time_ms = measurements[:decode_time] |> native_to_ms()
    query_time_ms = measurements[:query_time] |> native_to_ms()
    queue_time_ms = measurements[:queue_time] |> native_to_ms()

    # Extract query metadata
    source = metadata[:source] || "unknown"
    repo = metadata[:repo] |> to_string() |> String.split(".") |> List.last()

    # Record metrics
    ObservLib.histogram("ecto.query.total_time", total_time_ms, %{
      source: source,
      repo: repo
    })

    ObservLib.histogram("ecto.query.query_time", query_time_ms, %{
      source: source,
      repo: repo
    })

    if queue_time_ms > 0 do
      ObservLib.histogram("ecto.query.queue_time", queue_time_ms, %{
        source: source,
        repo: repo
      })
    end

    # Log slow queries
    if total_time_ms > 100 do
      ObservLib.Logs.warn("Slow query detected", %{
        source: source,
        total_time_ms: total_time_ms,
        query: metadata[:query] |> String.slice(0, 200)
      })
    end

    # Count queries
    ObservLib.counter("ecto.queries", 1, %{
      source: source,
      repo: repo
    })
  end

  defp native_to_ms(nil), do: 0
  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end
end
""")

# -----------------------------------------------------------------------------
# 2. Traced Repo Wrapper
# -----------------------------------------------------------------------------
IO.puts("--- 2. Traced Repo Wrapper ---")
IO.puts("""
# Option A: Create wrapper functions in your Repo module

defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres

  @doc \"\"\"
  Traced version of `all/2`.
  \"\"\"
  def traced_all(queryable, opts \\\\ []) do
    source = source_name(queryable)
    ObservLib.traced("Repo.all", %{"ecto.source" => source}, fn ->
      all(queryable, opts)
    end)
  end

  @doc \"\"\"
  Traced version of `get/3`.
  \"\"\"
  def traced_get(queryable, id, opts \\\\ []) do
    source = source_name(queryable)
    ObservLib.traced("Repo.get", %{"ecto.source" => source, "ecto.id" => id}, fn ->
      get(queryable, id, opts)
    end)
  end

  @doc \"\"\"
  Traced version of `get!/3`.
  \"\"\"
  def traced_get!(queryable, id, opts \\\\ []) do
    source = source_name(queryable)
    ObservLib.traced("Repo.get!", %{"ecto.source" => source, "ecto.id" => id}, fn ->
      get!(queryable, id, opts)
    end)
  end

  @doc \"\"\"
  Traced version of `insert/2`.
  \"\"\"
  def traced_insert(struct_or_changeset, opts \\\\ []) do
    source = source_name(struct_or_changeset)
    ObservLib.traced("Repo.insert", %{"ecto.source" => source}, fn ->
      result = insert(struct_or_changeset, opts)
      case result do
        {:ok, _} -> ObservLib.counter("ecto.inserts", 1, %{source: source})
        {:error, _} -> ObservLib.counter("ecto.insert_failures", 1, %{source: source})
      end
      result
    end)
  end

  @doc \"\"\"
  Traced version of `update/2`.
  \"\"\"
  def traced_update(changeset, opts \\\\ []) do
    source = source_name(changeset)
    ObservLib.traced("Repo.update", %{"ecto.source" => source}, fn ->
      result = update(changeset, opts)
      case result do
        {:ok, _} -> ObservLib.counter("ecto.updates", 1, %{source: source})
        {:error, _} -> ObservLib.counter("ecto.update_failures", 1, %{source: source})
      end
      result
    end)
  end

  @doc \"\"\"
  Traced version of `delete/2`.
  \"\"\"
  def traced_delete(struct_or_changeset, opts \\\\ []) do
    source = source_name(struct_or_changeset)
    ObservLib.traced("Repo.delete", %{"ecto.source" => source}, fn ->
      result = delete(struct_or_changeset, opts)
      case result do
        {:ok, _} -> ObservLib.counter("ecto.deletes", 1, %{source: source})
        {:error, _} -> ObservLib.counter("ecto.delete_failures", 1, %{source: source})
      end
      result
    end)
  end

  @doc \"\"\"
  Traced transaction wrapper.
  \"\"\"
  def traced_transaction(name, fun_or_multi, opts \\\\ []) do
    ObservLib.traced("Repo.transaction:\#{name}", fn ->
      case transaction(fun_or_multi, opts) do
        {:ok, result} ->
          ObservLib.counter("ecto.transactions.committed", 1)
          {:ok, result}
        {:error, reason} ->
          ObservLib.counter("ecto.transactions.rolled_back", 1)
          {:error, reason}
      end
    end)
  end

  # Helper to extract source/table name
  defp source_name(%Ecto.Query{from: %{source: {table, _}}}), do: table
  defp source_name(%Ecto.Changeset{data: %{__meta__: meta}}), do: meta.source
  defp source_name(%{__meta__: meta}), do: meta.source
  defp source_name(schema) when is_atom(schema), do: schema.__schema__(:source)
  defp source_name(_), do: "unknown"
end
""")

# -----------------------------------------------------------------------------
# 3. Query Complexity Tracking
# -----------------------------------------------------------------------------
IO.puts("--- 3. Query Complexity Tracking ---")
IO.puts("""
# Track complex queries with custom attributes

defmodule MyApp.Queries.Users do
  import Ecto.Query
  alias MyApp.{Repo, User}

  def list_with_posts(opts \\\\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query = from u in User,
      left_join: p in assoc(u, :posts),
      preload: [posts: p],
      limit: ^limit,
      offset: ^offset

    ObservLib.traced("Queries.Users.list_with_posts", %{
      "query.type" => "list_with_association",
      "query.limit" => limit,
      "query.offset" => offset,
      "query.joins" => 1
    }, fn ->
      users = Repo.all(query)
      ObservLib.gauge("users.listed_count", length(users))
      users
    end)
  end

  def search(term, opts \\\\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query = from u in User,
      where: ilike(u.name, ^"%\#{term}%") or ilike(u.email, ^"%\#{term}%"),
      limit: ^limit

    ObservLib.traced("Queries.Users.search", %{
      "query.type" => "search",
      "query.term_length" => String.length(term),
      "query.limit" => limit
    }, fn ->
      start = System.monotonic_time()
      results = Repo.all(query)
      duration_ms = System.monotonic_time() - start
                    |> System.convert_time_unit(:native, :millisecond)

      ObservLib.histogram("users.search_duration", duration_ms)
      ObservLib.histogram("users.search_result_count", length(results))

      if length(results) == 0 do
        ObservLib.Logs.debug("User search returned no results", term: term)
      end

      results
    end)
  end
end
""")

# -----------------------------------------------------------------------------
# 4. Connection Pool Monitoring
# -----------------------------------------------------------------------------
IO.puts("--- 4. Connection Pool Monitoring ---")
IO.puts("""
# Monitor database connection pool health

defmodule MyApp.DbPoolMonitor do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check_pool, state) do
    check_pool_stats()
    schedule_check()
    {:noreply, state}
  end

  defp schedule_check do
    Process.send_after(self(), :check_pool, 10_000) # Every 10 seconds
  end

  defp check_pool_stats do
    # Get pool stats (DBConnection 2.x)
    case DBConnection.get_connection_metrics(MyApp.Repo) do
      {:ok, metrics} ->
        ObservLib.gauge("ecto.pool.size", metrics.pool_size)
        ObservLib.gauge("ecto.pool.available", metrics.available)
        ObservLib.gauge("ecto.pool.checked_out", metrics.checked_out)

        utilization = metrics.checked_out / metrics.pool_size * 100
        ObservLib.gauge("ecto.pool.utilization_percent", utilization)

        if utilization > 80 do
          ObservLib.Logs.warn("High database pool utilization", %{
            utilization_percent: utilization,
            available: metrics.available
          })
        end

      _ ->
        :ok
    end
  end
end
""")

# -----------------------------------------------------------------------------
# 5. Migration Instrumentation
# -----------------------------------------------------------------------------
IO.puts("--- 5. Migration Instrumentation ---")
IO.puts("""
# Track migration execution

defmodule MyApp.Repo.Migrations.TracedMigration do
  @moduledoc \"\"\"
  Base module for traced migrations.
  \"\"\"

  defmacro __using__(_opts) do
    quote do
      use Ecto.Migration

      def traced_execute(operation_name, fun) do
        start = System.monotonic_time()

        result = fun.()

        duration_ms = System.monotonic_time() - start
                      |> System.convert_time_unit(:native, :millisecond)

        # Log migration step
        ObservLib.Logs.info("Migration step completed", %{
          migration: __MODULE__ |> to_string(),
          operation: operation_name,
          duration_ms: duration_ms
        })

        result
      end
    end
  end
end

# Usage in a migration:
defmodule MyApp.Repo.Migrations.AddUsersIndex do
  use MyApp.Repo.Migrations.TracedMigration

  def change do
    traced_execute("create_users_email_index", fn ->
      create index(:users, [:email], concurrently: true)
    end)
  end
end
""")

IO.puts("=== Ecto Integration Examples Complete ===")
IO.puts("""

Setup steps:
1. Call MyApp.EctoTelemetry.setup() in your application startup
2. Use traced_* functions from your Repo for automatic instrumentation
3. Add MyApp.DbPoolMonitor to your supervision tree for pool monitoring
4. Configure telemetry_events in observlib config:

   config :observlib,
     telemetry_events: [
       [:my_app, :repo, :query]
     ]
""")
