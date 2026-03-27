defmodule ObservLib.Telemetry do
  @moduledoc """
  Telemetry event handler integration for ObservLib.

  Bridges Erlang :telemetry events to OpenTelemetry traces and metrics.
  Supports attaching handlers for library instrumentation (Phoenix, Ecto, etc.)
  and custom application events.

  ## Example

      # Attach handlers for all configured event prefixes
      ObservLib.Telemetry.setup()

      # Attach a handler for a specific event prefix
      ObservLib.Telemetry.attach([:phoenix, :endpoint])

      # List all ObservLib-managed handlers
      ObservLib.Telemetry.list_handlers()

      # Detach a handler
      ObservLib.Telemetry.detach([:phoenix, :endpoint])

  """

  require Logger
  require OpenTelemetry.Tracer

  @type event_prefix :: [atom(), ...]
  @type handler_id :: atom()
  @type attach_opts :: keyword()

  @doc """
  Attach all configured default handlers.

  Reads `:telemetry_events` from the application environment and attaches
  handlers for each configured event prefix. Called during application startup.

  ## Returns

    * `:ok` - All handlers attached successfully
    * `{:error, term()}` - One or more handlers failed to attach

  ## Examples

      ObservLib.Telemetry.setup()
      #=> :ok

  """
  @spec setup() :: :ok | {:error, term()}
  def setup do
    events = Application.get_env(:observlib, :telemetry_events, [])
    setup(events: events)
  end

  @doc """
  Attach handlers with explicit options.

  ## Parameters

    * `opts` - Keyword list of options:
      * `:events` - List of event prefixes to attach handlers for

  ## Returns

    * `:ok` - All handlers attached successfully
    * `{:error, term()}` - One or more handlers failed to attach

  ## Examples

      ObservLib.Telemetry.setup(events: [[:phoenix, :endpoint], [:ecto, :repo]])
      #=> :ok

  """
  @spec setup(attach_opts()) :: :ok | {:error, term()}
  def setup(opts) when is_list(opts) do
    events = Keyword.get(opts, :events, [])

    results =
      Enum.map(events, fn prefix ->
        attach(prefix)
      end)

    errors = Enum.filter(results, fn
      {:error, _} -> true
      _ -> false
    end)

    case errors do
      [] -> :ok
      [{:error, reason} | _] -> {:error, reason}
    end
  end

  @doc """
  Attach a handler for a specific telemetry event prefix.

  The handler ID is automatically generated from the prefix using the
  `:observlib_` naming convention.

  ## Parameters

    * `prefix` - List of atoms representing the event prefix, e.g. `[:phoenix, :endpoint]`
    * `opts` - Keyword list of options:
      * `:handler` - Custom handler function `(event_name, measurements, metadata, config) -> any`

  ## Returns

    * `:ok` - Handler attached successfully
    * `{:error, :already_attached}` - A handler with this ID is already attached
    * `{:error, term()}` - Attachment failed for another reason

  ## Examples

      ObservLib.Telemetry.attach([:my_app, :request])
      #=> :ok

      ObservLib.Telemetry.attach([:my_app, :request], handler: &MyModule.handle_event/4)
      #=> :ok

  """
  @spec attach(event_prefix(), attach_opts()) :: :ok | {:error, term()}
  def attach(prefix, opts \\ []) when is_list(prefix) do
    id = handler_id(prefix)
    handler_fun = Keyword.get(opts, :handler, &__MODULE__.handle_event/4)
    config = default_handler_config()

    case :telemetry.attach(id, prefix, handler_fun, config) do
      :ok -> :ok
      {:error, :already_exists} -> {:error, :already_attached}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Detach a handler by event prefix.

  Idempotent: returns `:ok` even if no handler is attached for the given prefix.

  ## Parameters

    * `prefix` - The event prefix that was used when attaching the handler

  ## Returns

    * `:ok` - Handler detached (or was not attached)

  ## Examples

      ObservLib.Telemetry.detach([:my_app, :request])
      #=> :ok

  """
  @spec detach(event_prefix()) :: :ok
  def detach(prefix) when is_list(prefix) do
    id = handler_id(prefix)

    case :telemetry.detach(id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc """
  List all ObservLib-managed telemetry handlers.

  Filters the list of all telemetry handlers to only include those with
  handler IDs using the `:observlib_` prefix.

  ## Returns

  A list of handler info maps, each containing:
    * `:id` - The handler ID atom
    * `:event_name` - The event name list
    * `:function` - The handler function
    * `:config` - The handler configuration

  ## Examples

      ObservLib.Telemetry.attach([:my_app, :request])
      ObservLib.Telemetry.list_handlers()
      #=> [%{id: :observlib_my_app_request, event_name: [:my_app, :request], ...}]

  """
  @spec list_handlers() :: [map()]
  def list_handlers do
    :telemetry.list_handlers([])
    |> Enum.filter(fn %{id: id} ->
      id_str = Atom.to_string(id)
      String.starts_with?(id_str, "observlib_")
    end)
  end

  @doc """
  Default handler callback for telemetry events.

  Creates an OpenTelemetry span from the telemetry event. Also records
  duration measurements as histogram metrics when present.

  ## Parameters

    * `event_name` - The telemetry event name (list of atoms)
    * `measurements` - Map of measurements from the event
    * `metadata` - Map of metadata from the event
    * `config` - Handler configuration map

  ## Examples

      ObservLib.Telemetry.handle_event(
        [:my_app, :request, :stop],
        %{duration: 1_000_000},
        %{status: 200},
        %{}
      )

  """
  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event(event_name, measurements, metadata, _config) do
    span_name = span_name(event_name)
    tracer = :opentelemetry.get_tracer(:observlib)

    attributes =
      metadata
      |> Map.take(Map.keys(metadata))
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
        Map.put(acc, key, v)
      end)

    span_opts = %{attributes: attributes}

    :otel_tracer.with_span(tracer, span_name, span_opts, fn _span_ctx ->
      case extract_duration(measurements) do
        nil ->
          :ok

        duration_ms ->
          :otel_span.set_attribute(
            :otel_tracer.current_span_ctx(),
            "duration_ms",
            duration_ms
          )
      end
    end)

    :ok
  end

  # Private helpers

  @spec handler_id(event_prefix()) :: handler_id()
  defp handler_id(prefix) do
    suffix = prefix |> Enum.map(&Atom.to_string/1) |> Enum.join("_")
    String.to_atom("observlib_" <> suffix)
  end

  @spec default_handler_config() :: map()
  defp default_handler_config do
    %{tracer: :opentelemetry.get_tracer(:observlib)}
  end

  @spec span_name([atom()]) :: String.t()
  defp span_name(event_name) do
    event_name |> Enum.map(&Atom.to_string/1) |> Enum.join(".")
  end

  @spec extract_duration(map()) :: float() | nil
  defp extract_duration(measurements) do
    cond do
      Map.has_key?(measurements, :duration) ->
        native_to_ms(measurements.duration)

      Map.has_key?(measurements, :total_time) ->
        native_to_ms(measurements.total_time)

      Map.has_key?(measurements, :system_time) ->
        native_to_ms(measurements.system_time)

      true ->
        nil
    end
  end

  @spec native_to_ms(integer()) :: float()
  defp native_to_ms(native_time) do
    native_time / :erlang.convert_time_unit(1, :second, :native) * 1000.0
  end
end
