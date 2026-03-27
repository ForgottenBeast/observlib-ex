# Phoenix Integration Example
#
# This example shows how to integrate ObservLib with a Phoenix application.
# Copy the relevant parts into your Phoenix project.

IO.puts("=== Phoenix Integration Patterns ===\n")

# -----------------------------------------------------------------------------
# 1. Application Configuration (config/config.exs)
# -----------------------------------------------------------------------------
IO.puts("--- 1. Configuration ---")
IO.puts("""
# Add to config/config.exs:

config :observlib,
  service_name: "my_phoenix_app",
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),
  resource_attributes: %{
    "service.version" => Mix.Project.config()[:version],
    "deployment.environment" => Mix.env() |> to_string()
  },
  telemetry_events: [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :start],
    [:phoenix, :router_dispatch, :stop]
  ]
""")

# -----------------------------------------------------------------------------
# 2. Telemetry Setup (lib/my_app/telemetry.ex)
# -----------------------------------------------------------------------------
IO.puts("--- 2. Telemetry Module ---")
IO.puts("""
# Create lib/my_app/telemetry.ex:

defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    # Attach ObservLib handlers for Phoenix events
    ObservLib.Telemetry.setup()

    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),

      # VM Metrics
      last_value("vm.memory.total", unit: {:byte, :megabyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_memory, []},
      {__MODULE__, :measure_processes, []}
    ]
  end

  def measure_memory do
    ObservLib.gauge("vm.memory.total", :erlang.memory(:total))
    ObservLib.gauge("vm.memory.processes", :erlang.memory(:processes))
    ObservLib.gauge("vm.memory.binary", :erlang.memory(:binary))
  end

  def measure_processes do
    ObservLib.gauge("vm.process_count", :erlang.system_info(:process_count))
  end
end
""")

# -----------------------------------------------------------------------------
# 3. Request Logging Plug
# -----------------------------------------------------------------------------
IO.puts("--- 3. Request Logger Plug ---")
IO.puts("""
# Create lib/my_app_web/plugs/request_logger.ex:

defmodule MyAppWeb.Plugs.RequestLogger do
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    request_id = get_request_id(conn)
    start_time = System.monotonic_time()

    conn
    |> put_private(:observlib_request_id, request_id)
    |> put_private(:observlib_start_time, start_time)
    |> register_before_send(&log_response/1)
  end

  defp get_request_id(conn) do
    case get_req_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> generate_request_id()
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp log_response(conn) do
    request_id = conn.private[:observlib_request_id]
    start_time = conn.private[:observlib_start_time]
    duration_ms = System.monotonic_time() - start_time
                  |> System.convert_time_unit(:native, :millisecond)

    ObservLib.Logs.info("Request completed", %{
      request_id: request_id,
      method: conn.method,
      path: conn.request_path,
      status: conn.status,
      duration_ms: duration_ms
    })

    ObservLib.histogram("http.server.duration", duration_ms, %{
      method: conn.method,
      status: conn.status,
      route: conn.private[:phoenix_route] || "unknown"
    })

    ObservLib.counter("http.server.requests", 1, %{
      method: conn.method,
      status: conn.status
    })

    conn
  end
end

# Add to your endpoint.ex:
# plug MyAppWeb.Plugs.RequestLogger
""")

# -----------------------------------------------------------------------------
# 4. Controller Instrumentation
# -----------------------------------------------------------------------------
IO.puts("--- 4. Controller Instrumentation ---")
IO.puts("""
# In your controllers:

defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller

  def index(conn, _params) do
    ObservLib.traced("UserController.index", fn ->
      users = MyApp.Accounts.list_users()

      ObservLib.Logs.info("Listed users", count: length(users))

      render(conn, :index, users: users)
    end)
  end

  def show(conn, %{"id" => id}) do
    ObservLib.traced("UserController.show", %{"user.id" => id}, fn ->
      case MyApp.Accounts.get_user(id) do
        nil ->
          ObservLib.Logs.warn("User not found", user_id: id)
          conn
          |> put_status(:not_found)
          |> render(:not_found)

        user ->
          ObservLib.Logs.debug("User found", user_id: id)
          render(conn, :show, user: user)
      end
    end)
  end

  def create(conn, %{"user" => user_params}) do
    ObservLib.traced("UserController.create", fn ->
      case MyApp.Accounts.create_user(user_params) do
        {:ok, user} ->
          ObservLib.counter("users.created", 1)
          ObservLib.Logs.info("User created", user_id: user.id)

          conn
          |> put_status(:created)
          |> render(:show, user: user)

        {:error, changeset} ->
          ObservLib.counter("users.creation_failed", 1)
          ObservLib.Logs.warn("User creation failed",
            errors: changeset.errors |> inspect())

          conn
          |> put_status(:unprocessable_entity)
          |> render(:error, changeset: changeset)
      end
    end)
  end
end
""")

# -----------------------------------------------------------------------------
# 5. Context Module Pattern
# -----------------------------------------------------------------------------
IO.puts("--- 5. Context Module Pattern ---")
IO.puts("""
# In your context modules:

defmodule MyApp.Accounts do
  alias MyApp.Repo
  alias MyApp.Accounts.User

  def list_users do
    ObservLib.traced("Accounts.list_users", fn ->
      users = Repo.all(User)
      ObservLib.gauge("accounts.user_count", length(users))
      users
    end)
  end

  def get_user(id) do
    ObservLib.traced("Accounts.get_user", %{"user.id" => id}, fn ->
      Repo.get(User, id)
    end)
  end

  def create_user(attrs) do
    ObservLib.traced("Accounts.create_user", fn ->
      %User{}
      |> User.changeset(attrs)
      |> Repo.insert()
    end)
  end
end
""")

# -----------------------------------------------------------------------------
# 6. LiveView Instrumentation
# -----------------------------------------------------------------------------
IO.puts("--- 6. LiveView Instrumentation ---")
IO.puts("""
# In your LiveView modules:

defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    ObservLib.traced("DashboardLive.mount", fn ->
      ObservLib.counter("liveview.mounts", 1, %{view: "dashboard"})

      if connected?(socket) do
        # Subscribe to updates
        Phoenix.PubSub.subscribe(MyApp.PubSub, "dashboard:updates")
      end

      {:ok, assign(socket, data: load_data())}
    end)
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    ObservLib.traced("DashboardLive.refresh", fn ->
      ObservLib.counter("liveview.events", 1, %{view: "dashboard", event: "refresh"})
      {:noreply, assign(socket, data: load_data())}
    end)
  end

  defp load_data do
    ObservLib.traced("DashboardLive.load_data", fn ->
      # Load dashboard data
      %{users: 100, orders: 50}
    end)
  end
end
""")

IO.puts("=== Phoenix Integration Examples Complete ===")
IO.puts("""

To use these patterns:
1. Add observlib to your mix.exs dependencies
2. Configure observlib in config/config.exs
3. Create the Telemetry supervisor module
4. Add the request logger plug to your endpoint
5. Instrument controllers and contexts as shown
""")
