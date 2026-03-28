defmodule ObservLib.Traces do
  @moduledoc """
  Distributed tracing module for ObservLib.

  Provides a high-level Elixir API for OpenTelemetry spans, including
  starting/ending spans, setting attributes and status, recording exceptions,
  and executing functions within span contexts.
  """

  @doc """
  Starts a new span with the given name and attributes.

  ## Parameters

    * `name` - The span name (string or atom)
    * `attributes` - A map of span attributes (default: %{})

  ## Returns

  The span context record.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation", %{"user.id" => "123"})
      iex> ObservLib.Traces.end_span(span)

  """
  def start_span(name, attributes \\ %{}) do
    {:ok, safe_attrs} = ObservLib.Attributes.validate(attributes)
    tracer = :opentelemetry.get_tracer(:observlib)
    opts = %{attributes: safe_attrs}
    :otel_tracer.start_span(tracer, name, opts)
  end

  @doc """
  Ends the given span.

  ## Parameters

    * `span_ctx` - The span context to end

  ## Returns

  The updated span context with is_recording set to false.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation")
      iex> ObservLib.Traces.end_span(span)

  """
  def end_span(span_ctx) do
    :otel_span.end_span(span_ctx)
  end

  @doc """
  Sets an attribute on the current span.

  ## Parameters

    * `key` - The attribute key (string or atom)
    * `value` - The attribute value (string, number, boolean, or list)

  ## Returns

  `true` if the attribute was set successfully, `false` otherwise.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation")
      iex> :otel_tracer.set_current_span(span)
      iex> ObservLib.Traces.set_attribute("http.method", "GET")
      true

  """
  def set_attribute(key, value) do
    span_ctx = :otel_tracer.current_span_ctx()
    :otel_span.set_attribute(span_ctx, key, value)
  end

  @doc """
  Sets the status of the current span.

  ## Parameters

    * `status` - The status code (`:ok` or `:error`)
    * `message` - Optional status message (default: "")

  ## Returns

  `true` if the status was set successfully, `false` otherwise.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation")
      iex> :otel_tracer.set_current_span(span)
      iex> ObservLib.Traces.set_status(:ok)
      true

      iex> ObservLib.Traces.set_status(:error, "Operation failed")
      true

  """
  def set_status(status, message \\ "")

  def set_status(:ok, _message) do
    span_ctx = :otel_tracer.current_span_ctx()
    # OpenTelemetry uses atom :ok directly
    :otel_span.set_status(span_ctx, :ok)
  end

  def set_status(:error, message) when is_binary(message) do
    span_ctx = :otel_tracer.current_span_ctx()
    # OpenTelemetry uses atom :error directly
    :otel_span.set_status(span_ctx, :error, message)
  end

  def set_status(:error, message) when is_list(message) do
    set_status(:error, to_string(message))
  end

  @doc """
  Records an exception in the current span.

  ## Parameters

    * `exception` - The exception struct or tuple (e.g., `{:error, reason}`)

  ## Returns

  `true` if the exception was recorded successfully, `false` otherwise.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation")
      iex> :otel_tracer.set_current_span(span)
      iex> try do
      ...>   raise "Something went wrong"
      ...> rescue
      ...>   e -> ObservLib.Traces.record_exception(e)
      ...> end

  """
  def record_exception(exception) do
    span_ctx = :otel_tracer.current_span_ctx()

    case exception do
      %{__exception__: true, __struct__: module} = ex ->
        # Elixir exception
        stacktrace = Process.info(self(), :current_stacktrace) |> elem(1)
        message = Exception.message(ex)
        :otel_span.record_exception(span_ctx, :error, module, message, stacktrace, %{})

      {kind, reason} ->
        # Erlang-style error tuple
        stacktrace = Process.info(self(), :current_stacktrace) |> elem(1)
        :otel_span.record_exception(span_ctx, kind, reason, stacktrace, %{})

      _ ->
        # Unknown format
        stacktrace = Process.info(self(), :current_stacktrace) |> elem(1)
        :otel_span.record_exception(span_ctx, :error, exception, stacktrace, %{})
    end
  end

  @doc """
  Executes a function within a span context.

  The span is automatically started before the function executes and ended
  after it completes (even if an exception is raised).

  ## Parameters

    * `name` - The span name (string or atom)
    * `attributes` - A map of span attributes (default: %{})
    * `fun` - The function to execute within the span

  ## Returns

  The return value of the function.

  ## Examples

      iex> result = ObservLib.Traces.with_span("database_query", %{"db.system" => "postgresql"}, fn ->
      ...>   # Perform database query
      ...>   {:ok, "result"}
      ...> end)
      {:ok, "result"}

  """
  def with_span(name, attributes \\ %{}, fun) when is_function(fun, 0) do
    {:ok, safe_attrs} = ObservLib.Attributes.validate(attributes)
    tracer = :opentelemetry.get_tracer(:observlib)
    opts = %{attributes: safe_attrs}

    :otel_tracer.with_span(tracer, name, opts, fn _span_ctx ->
      fun.()
    end)
  end

  @doc """
  Gets the current active span context.

  ## Returns

  The current span context or `nil` if no span is active.

  ## Examples

      iex> span = ObservLib.Traces.start_span("my_operation")
      iex> :otel_tracer.set_current_span(span)
      iex> current = ObservLib.Traces.current_span()
      iex> is_map(current)
      true

  """
  def current_span do
    :otel_tracer.current_span_ctx()
  end
end
