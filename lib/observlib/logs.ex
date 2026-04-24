defmodule ObservLib.Logs do
  @moduledoc """
  Structured logging with OpenTelemetry integration.

  Provides functions for emitting structured logs with levels and attributes,
  integrating with Elixir's Logger and OpenTelemetry logging infrastructure.

  ## Example

      # Simple logging
      ObservLib.Logs.info("User logged in", user_id: 123)

      # Structured logging with attributes
      ObservLib.Logs.log(:warn, "High memory usage", %{
        memory_mb: 1024,
        threshold_mb: 800
      })

      # Add context to multiple log statements
      ObservLib.Logs.with_context(%{request_id: "abc-123"}, fn ->
        ObservLib.Logs.info("Processing request")
        ObservLib.Logs.debug("Validating input")
      end)
  """

  require Logger

  @type log_level :: :debug | :info | :warn | :error
  @type attributes :: map() | keyword()

  # Logger handler ID for OpenTelemetry integration
  @handler_id :observlib_otel_logger

  @doc """
  Emits a structured log with the specified level and attributes.

  ## Parameters

    - `level` - Log level (`:debug`, `:info`, `:warn`, or `:error`)
    - `message` - Log message string
    - `attributes` - Map or keyword list of structured attributes

  ## Examples

      ObservLib.Logs.log(:info, "User action", %{user_id: 123, action: "login"})
      ObservLib.Logs.log(:error, "Failed to connect", error: "timeout")
  """
  @spec log(log_level(), String.t(), attributes()) :: :ok
  def log(level, message, attributes \\ []) when is_atom(level) and is_binary(message) do
    # Normalize attributes to a map
    attrs = normalize_attributes(attributes)

    # Validate and sanitize attributes
    {:ok, safe_attrs} = ObservLib.Attributes.validate(attrs)

    # Merge with process context if available
    merged_attrs = merge_with_context(safe_attrs)

    # Log with metadata
    Logger.log(level, message, merged_attrs)

    :ok
  end

  @doc """
  Logs a debug-level message with optional attributes.

  ## Examples

      ObservLib.Logs.debug("Cache miss", key: "user:123")
  """
  @spec debug(String.t(), attributes()) :: :ok
  def debug(message, attributes \\ []) do
    log(:debug, message, attributes)
  end

  @doc """
  Logs an info-level message with optional attributes.

  ## Examples

      ObservLib.Logs.info("Request processed", duration_ms: 42)
  """
  @spec info(String.t(), attributes()) :: :ok
  def info(message, attributes \\ []) do
    log(:info, message, attributes)
  end

  @doc """
  Logs a warning-level message with optional attributes.

  ## Examples

      ObservLib.Logs.warn("Retry attempted", attempt: 3, max_attempts: 5)
  """
  @spec warn(String.t(), attributes()) :: :ok
  def warn(message, attributes \\ []) do
    log(:warn, message, attributes)
  end

  @doc """
  Logs an error-level message with optional attributes.

  ## Examples

      ObservLib.Logs.error("Database connection failed", error: "timeout")
  """
  @spec error(String.t(), attributes()) :: :ok
  def error(message, attributes \\ []) do
    log(:error, message, attributes)
  end

  @doc """
  Attaches the OpenTelemetry logger handler.

  This enables integration with OpenTelemetry's logging pipeline, allowing
  logs to be exported via OTLP alongside traces and metrics.

  Returns `:ok` if the handler is attached successfully, or `{:error, reason}`
  if attachment fails.

  ## Examples

      ObservLib.Logs.attach_logger_handler()
      #=> :ok
  """
  @spec attach_logger_handler() :: :ok | {:error, term()}
  def attach_logger_handler do
    handler_config = %{
      config: %{},
      level: :all
    }

    case :logger.add_handler(@handler_id, :logger_std_h, handler_config) do
      :ok ->
        :ok

      {:error, {:already_exist, _}} ->
        # Handler already exists, consider it success
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Detaches the OpenTelemetry logger handler.

  Removes the OpenTelemetry logging integration. Logs will continue to be
  emitted through the standard Elixir Logger.

  Returns `:ok` if the handler is detached successfully, or `{:error, reason}`
  if detachment fails.

  ## Examples

      ObservLib.Logs.detach_logger_handler()
      #=> :ok
  """
  @spec detach_logger_handler() :: :ok | {:error, term()}
  def detach_logger_handler do
    case :logger.remove_handler(@handler_id) do
      :ok ->
        :ok

      {:error, {:not_found, _}} ->
        # Handler doesn't exist, consider it success
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a function with additional context attributes added to all logs.

  Context attributes are stored in the process dictionary and automatically
  merged with log attributes within the function scope.

  ## Parameters

    - `context` - Map or keyword list of context attributes
    - `fun` - Function to execute with the context

  ## Examples

      ObservLib.Logs.with_context(%{request_id: "abc-123"}, fn ->
        ObservLib.Logs.info("Processing request")
        # Logs will include request_id: "abc-123"
      end)
  """
  @spec with_context(attributes(), (-> result)) :: result when result: any()
  def with_context(context, fun) when is_function(fun, 0) do
    # Normalize context to a map
    ctx_map = normalize_attributes(context)

    # Get existing context and merge
    existing_context = Process.get(:observlib_log_context, %{})
    new_context = Map.merge(existing_context, ctx_map)

    # Store in process dictionary
    Process.put(:observlib_log_context, new_context)

    try do
      fun.()
    after
      # Restore previous context
      if map_size(existing_context) == 0 do
        Process.delete(:observlib_log_context)
      else
        Process.put(:observlib_log_context, existing_context)
      end
    end
  end

  # Private functions

  @spec normalize_attributes(attributes()) :: map()
  defp normalize_attributes(attrs) when is_map(attrs), do: attrs
  defp normalize_attributes(attrs) when is_list(attrs), do: Map.new(attrs)

  @spec merge_with_context(map()) :: keyword()
  defp merge_with_context(attrs) do
    case Process.get(:observlib_log_context) do
      nil ->
        Map.to_list(attrs)

      context when is_map(context) ->
        context
        |> Map.merge(attrs)
        |> Map.to_list()
    end
  end
end
