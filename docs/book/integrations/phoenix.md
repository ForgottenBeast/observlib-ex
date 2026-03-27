# Phoenix Framework Integration

ObservLib integrates seamlessly with Phoenix to provide automatic instrumentation for HTTP requests, router dispatch, and LiveView events.

## Quick Setup

### 1. Configuration

Add telemetry events to your config:

```elixir
# config/config.exs
config :observlib,
  service_name: "my_phoenix_app",
  otlp_endpoint: System.get_env("OTLP_ENDPOINT"),
  telemetry_events: [
    [:phoenix, :endpoint, :start],
    [:phoenix, :endpoint, :stop],
    [:phoenix, :router_dispatch, :start],
    [:phoenix, :router_dispatch, :stop]
  ]
```

### 2. Telemetry Module

Create a telemetry supervisor in your application:

```elixir
# lib/my_app/telemetry.ex
defmodule MyApp.Telemetry do
  use Supervisor

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
```

Add to your application supervision tree:

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    MyApp.Repo,
    MyAppWeb.Endpoint,
    MyApp.Telemetry  # Add this
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

## Request Logger Plug

Create a plug to log HTTP requests with trace context:

```elixir
# lib/my_app_web/plugs/request_logger.ex
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
```

Add to your endpoint:

```elixir
# lib/my_app_web/endpoint.ex
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # ... other plugs ...

  plug MyAppWeb.Plugs.RequestLogger  # Add this

  plug MyAppWeb.Router
end
```

## Controller Instrumentation

Instrument your controllers with traces:

```elixir
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller
  use ObservLib.Traced

  @traced attributes: %{"controller" => "users"}
  def index(conn, _params) do
    users = MyApp.Accounts.list_users()

    ObservLib.Logs.info("Listed users", count: length(users))

    render(conn, :index, users: users)
  end

  @traced attributes: %{"controller" => "users", "action" => "show"}
  def show(conn, %{"id" => id}) do
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
  end

  @traced attributes: %{"controller" => "users", "action" => "create"}
  def create(conn, %{"user" => user_params}) do
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
  end
end
```

## Context Module Instrumentation

Instrument your Phoenix contexts:

```elixir
defmodule MyApp.Accounts do
  use ObservLib.Traced
  alias MyApp.Repo
  alias MyApp.Accounts.User

  @traced attributes: %{"context" => "accounts"}
  def list_users do
    users = Repo.all(User)
    ObservLib.gauge("accounts.user_count", length(users))
    users
  end

  @traced attributes: %{"context" => "accounts", "operation" => "get"}
  def get_user(id) do
    Repo.get(User, id)
  end

  @traced attributes: %{"context" => "accounts", "operation" => "create"}
  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end
end
```

## LiveView Instrumentation

Instrument LiveView mount and events:

```elixir
defmodule MyAppWeb.DashboardLive do
  use MyAppWeb, :live_view
  use ObservLib.Traced

  @traced attributes: %{"live_view" => "dashboard"}
  def mount(_params, session, socket) do
    ObservLib.counter("liveview.mounts", 1, %{view: "dashboard"})

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "dashboard:updates")
    end

    {:ok, assign(socket, data: load_data())}
  end

  @traced attributes: %{"live_view" => "dashboard", "event" => "refresh"}
  def handle_event("refresh", _params, socket) do
    ObservLib.counter("liveview.events", 1, %{view: "dashboard", event: "refresh"})
    {:noreply, assign(socket, data: load_data())}
  end

  @traced
  defp load_data do
    # Load dashboard data
    %{users: 100, orders: 50}
  end
end
```

## Error Tracking

Track Phoenix errors:

```elixir
# lib/my_app_web/controllers/fallback_controller.ex
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  def call(conn, {:error, :not_found}) do
    ObservLib.counter("http.errors", 1, %{type: "not_found"})
    ObservLib.Logs.warn("Resource not found", path: conn.request_path)

    conn
    |> put_status(:not_found)
    |> put_view(MyAppWeb.ErrorView)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    ObservLib.counter("http.errors", 1, %{type: "unauthorized"})
    ObservLib.Logs.warn("Unauthorized access", path: conn.request_path)

    conn
    |> put_status(:forbidden)
    |> put_view(MyAppWeb.ErrorView)
    |> render(:"403")
  end
end
```

## Testing with Instrumentation

Test your instrumented code:

```elixir
deftest "GET /users returns users" do
  # Create test users
  user1 = insert(:user)
  user2 = insert(:user)

  # Make request (will be instrumented)
  conn = get(build_conn(), "/users")

  # Verify response
  assert json_response(conn, 200) == [
    %{"id" => user1.id, ...},
    %{"id" => user2.id, ...}
  ]

  # Verify metrics were recorded (if needed)
  # Note: Typically you don't assert on metrics in unit tests
end
```

## Performance Impact

ObservLib's Phoenix instrumentation adds minimal overhead:

- **Per-request overhead**: ~50-100μs
- **Controller instrumentation**: ~10-20μs per action
- **Memory**: ~500 bytes per request span

For high-throughput applications, consider sampling.

## Complete Example

See [examples/phoenix_integration.exs](../../examples/phoenix_integration.exs) for a complete runnable example.

## Next Steps

- [Ecto Integration](ecto.md) - Instrument database queries
- [Custom Instrumentation](../guides/custom-instrumentation.md) - Advanced patterns
- [Deployment](../deployment/production-config.md) - Production configuration
