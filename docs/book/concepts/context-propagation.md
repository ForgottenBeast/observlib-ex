# Context Propagation

Context propagation is critical for distributed tracing in Elixir applications. When you spawn a new process, use `Task.async`, or send messages to a GenServer, **trace context doesn't automatically propagate** because each Elixir process has its own isolated process dictionary.

This guide explains how to manually propagate OpenTelemetry context across process boundaries to maintain trace continuity.

## The Problem

OpenTelemetry stores trace context (trace_id, span_id, trace flags, and baggage) in the **process dictionary** by default. When you create a new process, it starts with a fresh, empty process dictionary:

```elixir
ObservLib.traced("parent_operation", fn ->
  # Trace context exists in THIS process

  Task.async(fn ->
    # NEW process - trace context is LOST
    # Spans created here will start a new, disconnected trace
    ObservLib.traced("child_work", fn ->
      expensive_computation()
    end)
  end)
end)
```

**Result**: The child span appears as a separate trace in your observability backend, disconnected from the parent.

## The Solution: Manual Context Propagation

To propagate context across processes, you must:

1. **Capture** the context in the parent process using `:otel_ctx.get_current()`
2. **Pass** the context to the child process (as a function argument, message payload, etc.)
3. **Attach** the context in the child process using `:otel_ctx.attach(ctx)`

## Patterns

### Task.async Pattern

Use this pattern when spawning async tasks:

```elixir
ObservLib.traced("parent_operation", fn ->
  # Step 1: Capture context in parent
  ctx = :otel_ctx.get_current()

  # Step 2: Pass to child task
  task = Task.async(fn ->
    # Step 3: Attach in child
    :otel_ctx.attach(ctx)

    # Now spans will be part of the parent trace
    ObservLib.traced("child_operation", fn ->
      expensive_work()
    end)
  end)

  result = Task.await(task)
  {:ok, result}
end)
```

**Multiple Tasks**: Fire them in parallel with context:

```elixir
ctx = :otel_ctx.get_current()

tasks = [
  Task.async(fn ->
    :otel_ctx.attach(ctx)
    ObservLib.traced("task_1", fn -> work_1() end)
  end),
  Task.async(fn ->
    :otel_ctx.attach(ctx)
    ObservLib.traced("task_2", fn -> work_2() end)
  end),
  Task.async(fn ->
    :otel_ctx.attach(ctx)
    ObservLib.traced("task_3", fn -> work_3() end)
  end)
]

results = Task.await_many(tasks)
```

### spawn/spawn_link Pattern

For raw process spawning:

```elixir
ObservLib.traced("parent_operation", fn ->
  ctx = :otel_ctx.get_current()

  pid = spawn(fn ->
    :otel_ctx.attach(ctx)

    ObservLib.traced("spawned_work", fn ->
      do_background_work()
    end)
  end)

  # Continue with other work
  do_parent_work()
end)
```

### GenServer Call Pattern

When making synchronous GenServer calls:

```elixir
defmodule MyWorker do
  use GenServer

  # Client API - captures and passes context
  def process_with_trace(pid, data) do
    ctx = :otel_ctx.get_current()
    GenServer.call(pid, {:process, data, ctx})
  end

  # Server callback - attaches context
  def handle_call({:process, data, ctx}, _from, state) do
    :otel_ctx.attach(ctx)

    result = ObservLib.traced("worker_process", %{"data.id" => data.id}, fn ->
      do_processing(data)
    end)

    {:reply, result, state}
  end
end

# Usage
ObservLib.traced("main_flow", fn ->
  result = MyWorker.process_with_trace(worker_pid, %{id: 123, payload: "..."})
  {:ok, result}
end)
```

### GenServer Cast Pattern

For asynchronous GenServer messages:

```elixir
defmodule MyWorker do
  use GenServer

  # Client API
  def process_async(pid, data) do
    ctx = :otel_ctx.get_current()
    GenServer.cast(pid, {:process, data, ctx})
  end

  # Server callback
  def handle_cast({:process, data, ctx}, state) do
    :otel_ctx.attach(ctx)

    ObservLib.traced("async_work", fn ->
      process_data(data)
    end)

    {:noreply, state}
  end
end
```

### send/receive Pattern

For direct message passing:

```elixir
defmodule MessageWorker do
  def start_link do
    ctx = :otel_ctx.get_current()

    spawn_link(fn ->
      receive do
        {:work, data, parent_ctx} ->
          :otel_ctx.attach(parent_ctx)

          ObservLib.traced("message_work", fn ->
            process(data)
          end)
      end
    end)
  end
end

# Usage
ObservLib.traced("sender", fn ->
  ctx = :otel_ctx.get_current()
  pid = MessageWorker.start_link()
  send(pid, {:work, %{id: 1}, ctx})
end)
```

## Helper Module Pattern

Create reusable helpers to reduce boilerplate:

```elixir
defmodule MyApp.Tracing do
  @moduledoc """
  Tracing utilities with automatic context propagation.
  """

  @doc "Spawn async task with trace context"
  def traced_async(fun) when is_function(fun, 0) do
    ctx = :otel_ctx.get_current()

    Task.async(fn ->
      :otel_ctx.attach(ctx)
      fun.()
    end)
  end

  @doc "Spawn async task with multiple arguments"
  def traced_async(module, function, args) do
    ctx = :otel_ctx.get_current()

    Task.async(fn ->
      :otel_ctx.attach(ctx)
      apply(module, function, args)
    end)
  end

  @doc "Spawn process with trace context"
  def traced_spawn(fun) when is_function(fun, 0) do
    ctx = :otel_ctx.get_current()

    spawn(fn ->
      :otel_ctx.attach(ctx)
      fun.()
    end)
  end

  @doc "Spawn linked process with trace context"
  def traced_spawn_link(fun) when is_function(fun, 0) do
    ctx = :otel_ctx.get_current()

    spawn_link(fn ->
      :otel_ctx.attach(ctx)
      fun.()
    end)
  end
end
```

**Usage**:

```elixir
alias MyApp.Tracing

ObservLib.traced("parent", fn ->
  # Simple async with context
  task = Tracing.traced_async(fn ->
    ObservLib.traced("child_work", fn ->
      expensive_operation()
    end)
  end)

  Task.await(task)
end)
```

## Testing Context Propagation

Verify that context propagates correctly by checking trace_id continuity:

```elixir
defmodule MyApp.TracingTest do
  use ExUnit.Case

  test "context propagates across Task.async" do
    ObservLib.traced("test_parent", fn ->
      parent_span = ObservLib.Traces.current_span()
      parent_trace_id = extract_trace_id(parent_span)

      ctx = :otel_ctx.get_current()

      task = Task.async(fn ->
        :otel_ctx.attach(ctx)

        ObservLib.traced("test_child", fn ->
          child_span = ObservLib.Traces.current_span()
          child_trace_id = extract_trace_id(child_span)

          # Trace IDs should match
          assert child_trace_id == parent_trace_id
          :ok
        end)
      end)

      assert :ok = Task.await(task)
    end)
  end

  defp extract_trace_id(span_ctx) do
    # Extract trace_id from OpenTelemetry span context tuple
    # Format: {:span_ctx, trace_id, span_id, ...}
    elem(span_ctx, 1)
  end
end
```

## Troubleshooting

### Problem: Child spans appear as separate traces

**Symptom**: Spans in child processes don't appear under the parent trace in your observability backend.

**Cause**: Context was not propagated correctly.

**Fix**: Verify you're calling `:otel_ctx.attach(ctx)` at the start of the child process function.

```elixir
# ❌ Wrong - forgot to attach
Task.async(fn ->
  ObservLib.traced("work", fn -> ... end)  # Starts new trace
end)

# ✅ Correct
ctx = :otel_ctx.get_current()
Task.async(fn ->
  :otel_ctx.attach(ctx)  # Attach first!
  ObservLib.traced("work", fn -> ... end)
end)
```

### Problem: Context is nil or invalid

**Symptom**: `:otel_ctx.get_current()` returns `nil` or invalid context.

**Cause**: No active span when capturing context.

**Fix**: Ensure you're inside a span when capturing:

```elixir
# ❌ Wrong - no active span
ctx = :otel_ctx.get_current()  # Returns nil or default context
ObservLib.traced("parent", fn ->
  Task.async(fn ->
    :otel_ctx.attach(ctx)  # Attaching nil doesn't help
  end)
end)

# ✅ Correct - capture inside span
ObservLib.traced("parent", fn ->
  ctx = :otel_ctx.get_current()  # Now there's an active span
  Task.async(fn ->
    :otel_ctx.attach(ctx)
  end)
end)
```

### Problem: GenServer state grows with stale contexts

**Symptom**: Memory usage increases over time in GenServer processes.

**Cause**: Storing contexts in state without cleanup.

**Fix**: Pass context per-message, don't store in state:

```elixir
# ❌ Wrong - storing in state
def handle_call(:work, _from, state) do
  # Using old context from state
  :otel_ctx.attach(state.ctx)
  ...
end

# ✅ Correct - pass per-message
def handle_call({:work, ctx}, _from, state) do
  # Fresh context from caller
  :otel_ctx.attach(ctx)
  ...
end
```

## Best Practices

1. **Capture Early**: Call `:otel_ctx.get_current()` as close as possible to the process boundary
2. **Attach First**: Always attach context before creating any spans in the child process
3. **Use Helpers**: Create helper functions to reduce boilerplate and prevent mistakes
4. **Test Propagation**: Write tests that verify trace_id continuity across processes
5. **Document APIs**: When creating functions that spawn processes, document whether they handle context propagation

## Performance Considerations

Context propagation has minimal overhead:

- `:otel_ctx.get_current()`: ~0.1-0.5 microseconds (process dictionary read)
- `:otel_ctx.attach(ctx)`: ~0.1-0.5 microseconds (process dictionary write)
- Context passing: Adds one extra argument to function calls (negligible)

The benefits of complete trace visibility far outweigh this tiny cost.

## Further Reading

- [OpenTelemetry Context Specification](https://opentelemetry.io/docs/specs/otel/context/)
- [Elixir Process Dictionary Documentation](https://hexdocs.pm/elixir/Process.html#get/1)
- [Custom Instrumentation Guide](../guides/custom-instrumentation.md)
- [Architecture Overview](architecture.md)
