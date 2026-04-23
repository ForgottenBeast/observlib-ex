defmodule ObservLib.Traced do
  @moduledoc """
  Macro module for automatic span creation via function decoration.

  Provides two usage patterns for instrumenting functions with OpenTelemetry spans:

  ## Pattern A: Module-level decoration with `@traced`

      defmodule MyApp.UserService do
        use ObservLib.Traced

        @traced attributes: %{"service" => "users"}
        def get_user(id) do
          # automatically wrapped in a span named "MyApp.UserService.get_user/1"
          Repo.get(User, id)
        end

        @traced name: "custom_span_name"
        def create_user(params) do
          # wrapped in a span named "custom_span_name"
          Repo.insert(User.changeset(%User{}, params))
        end
      end

  ## Pattern B: Inline block wrapping with `traced/3`

      defmodule MyApp.Worker do
        import ObservLib.Traced

        def process(item) do
          traced "process_item", %{item_id: item.id} do
            # block is wrapped in span
            heavy_computation(item)
          end
        end
      end

  ## Options for `@traced`

    * `:name` - Custom span name (default: "Module.function/arity")
    * `:attributes` - Static attributes map to include in the span

  ## Exception Handling

  When an exception is raised within a traced function or block:
  1. The span status is set to `:error`
  2. The exception is recorded on the span
  3. The exception is re-raised

  """

  @doc """
  Inline macro for wrapping a block in a span.

  ## Parameters

    * `name` - The span name (string)
    * `attributes` - A map of span attributes (default: %{})
    * `do: block` - The block to execute within the span

  ## Examples

      import ObservLib.Traced

      def my_function do
        traced "database_query", %{table: "users"} do
          Repo.all(User)
        end
      end

  """
  defmacro traced(name, attributes \\ Macro.escape(%{}), do: block) do
    quote do
      ObservLib.Traces.with_span(unquote(name), unquote(attributes), fn ->
        try do
          unquote(block)
        rescue
          e ->
            ObservLib.Traces.set_status(:error, Exception.message(e))
            ObservLib.Traces.record_exception(e)
            reraise e, __STACKTRACE__
        end
      end)
    end
  end

  @doc false
  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :traced, accumulate: false)
      Module.register_attribute(__MODULE__, :observlib_traced_functions, accumulate: true)

      @on_definition {ObservLib.Traced, :__on_definition__}
      @before_compile {ObservLib.Traced, :__before_compile__}

      import ObservLib.Traced, only: [traced: 2, traced: 3]
    end
  end

  @doc false
  def __on_definition__(env, kind, name, args, guards, _body) when kind in [:def, :defp] do
    traced_opts = Module.get_attribute(env.module, :traced)

    if traced_opts != nil do
      # Store the function info for later rewriting
      arity = length(args)

      func_info = %{
        kind: kind,
        name: name,
        arity: arity,
        args: args,
        guards: guards,
        opts: normalize_traced_opts(traced_opts),
        module: env.module
      }

      Module.put_attribute(env.module, :observlib_traced_functions, func_info)
      # Clear the @traced attribute for the next function
      Module.delete_attribute(env.module, :traced)
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: nil

  @doc false
  defmacro __before_compile__(env) do
    traced_functions = Module.get_attribute(env.module, :observlib_traced_functions) || []

    # Group by {name, arity} to handle multi-clause functions
    grouped =
      traced_functions
      |> Enum.reverse()
      |> Enum.group_by(fn %{name: name, arity: arity} -> {name, arity} end)

    overrides =
      for {{name, arity}, [first | _] = _clauses} <- grouped do
        %{kind: kind, opts: opts, module: module} = first

        span_name = opts[:name] || default_span_name(module, name, arity)
        attributes = opts[:attributes] || %{}

        generate_override(kind, name, arity, span_name, attributes)
      end

    quote do
      (unquote_splicing(overrides))
    end
  end

  # Private helpers

  defp normalize_traced_opts(true), do: []
  defp normalize_traced_opts(opts) when is_list(opts), do: opts
  defp normalize_traced_opts(_), do: []

  defp default_span_name(module, name, arity) do
    "#{inspect(module)}.#{name}/#{arity}"
  end

  defp generate_override(:def, name, arity, span_name, attributes) do
    args = generate_args(arity)

    quote do
      defoverridable [{unquote(name), unquote(arity)}]

      def unquote(name)(unquote_splicing(args)) do
        ObservLib.Traces.with_span(unquote(span_name), unquote(Macro.escape(attributes)), fn ->
          try do
            super(unquote_splicing(args))
          rescue
            e ->
              ObservLib.Traces.set_status(:error, Exception.message(e))
              ObservLib.Traces.record_exception(e)
              reraise e, __STACKTRACE__
          end
        end)
      end
    end
  end

  defp generate_override(:defp, name, arity, span_name, attributes) do
    args = generate_args(arity)

    quote do
      defoverridable [{unquote(name), unquote(arity)}]

      defp unquote(name)(unquote_splicing(args)) do
        ObservLib.Traces.with_span(unquote(span_name), unquote(Macro.escape(attributes)), fn ->
          try do
            super(unquote_splicing(args))
          rescue
            e ->
              ObservLib.Traces.set_status(:error, Exception.message(e))
              ObservLib.Traces.record_exception(e)
              reraise e, __STACKTRACE__
          end
        end)
      end
    end
  end

  defp generate_args(0), do: []

  defp generate_args(arity) do
    for i <- 1..arity do
      Macro.var(:"arg#{i}", __MODULE__)
    end
  end
end
