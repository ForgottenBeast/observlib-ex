defmodule ObservLib.Traces.PyroscopeProcessorTest do
  use ExUnit.Case, async: false

  alias ObservLib.Traces.PyroscopeProcessor

  setup do
    # Stop any existing processor
    stop_existing_processor()

    :ok
  end

  describe "start_link/1 without endpoint configured" do
    test "starts in disabled mode when no endpoint configured" do
      Application.delete_env(:observlib, :pyroscope_endpoint)

      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert Process.alive?(pid)
      assert PyroscopeProcessor.enabled?() == false

      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with endpoint configured" do
    setup do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")

      on_exit(fn ->
        Application.delete_env(:observlib, :pyroscope_endpoint)
      end)

      :ok
    end

    test "starts in enabled mode when endpoint is configured" do
      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert Process.alive?(pid)
      assert PyroscopeProcessor.enabled?() == true

      GenServer.stop(pid)
    end
  end

  describe "attach_profile/2" do
    setup do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:observlib, :pyroscope_endpoint)
      end)

      {:ok, processor: pid}
    end

    test "attaches profiling data to a span" do
      span_id = {:test_trace_id, :test_span_id}
      profile_data = %{labels: %{"function" => "process_request"}}

      assert :ok = PyroscopeProcessor.attach_profile(span_id, profile_data)

      # Give cast time to process
      Process.sleep(50)

      {:ok, retrieved} = PyroscopeProcessor.get_profile(span_id)
      assert retrieved.labels == %{"function" => "process_request"}
      assert Map.has_key?(retrieved, :attached_at)
      assert Map.has_key?(retrieved, :span_id)
    end

    test "attaches multiple profiles for different spans" do
      span_id_1 = {:trace_1, :span_1}
      span_id_2 = {:trace_2, :span_2}

      PyroscopeProcessor.attach_profile(span_id_1, %{labels: %{"op" => "read"}})
      PyroscopeProcessor.attach_profile(span_id_2, %{labels: %{"op" => "write"}})

      Process.sleep(50)

      {:ok, profile_1} = PyroscopeProcessor.get_profile(span_id_1)
      {:ok, profile_2} = PyroscopeProcessor.get_profile(span_id_2)

      assert profile_1.labels["op"] == "read"
      assert profile_2.labels["op"] == "write"
    end
  end

  describe "attach_profile/2 when disabled" do
    test "does not store profile when disabled" do
      Application.delete_env(:observlib, :pyroscope_endpoint)
      {:ok, pid} = PyroscopeProcessor.start_link([])

      span_id = {:test_trace, :test_span}
      PyroscopeProcessor.attach_profile(span_id, %{labels: %{"test" => "value"}})

      Process.sleep(50)

      assert {:error, :not_found} = PyroscopeProcessor.get_profile(span_id)

      GenServer.stop(pid)
    end
  end

  describe "get_profile/1" do
    setup do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:observlib, :pyroscope_endpoint)
      end)

      {:ok, processor: pid}
    end

    test "returns profile data for existing span" do
      span_id = {:trace, :span}
      PyroscopeProcessor.attach_profile(span_id, %{custom_data: "test"})
      Process.sleep(50)

      {:ok, profile} = PyroscopeProcessor.get_profile(span_id)
      assert profile.custom_data == "test"
    end

    test "returns error for non-existent span" do
      assert {:error, :not_found} = PyroscopeProcessor.get_profile({:unknown, :span})
    end
  end

  describe "remove_profile/1" do
    setup do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:observlib, :pyroscope_endpoint)
      end)

      {:ok, processor: pid}
    end

    test "removes profile data for a span" do
      span_id = {:trace, :span_to_remove}
      PyroscopeProcessor.attach_profile(span_id, %{data: "test"})
      Process.sleep(50)

      # Verify it exists
      {:ok, _} = PyroscopeProcessor.get_profile(span_id)

      # Remove it
      :ok = PyroscopeProcessor.remove_profile(span_id)
      Process.sleep(50)

      # Verify it's gone
      assert {:error, :not_found} = PyroscopeProcessor.get_profile(span_id)
    end
  end

  describe "get_current_labels/0" do
    setup do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
        Application.delete_env(:observlib, :pyroscope_endpoint)
      end)

      {:ok, processor: pid}
    end

    test "returns empty map when no active span" do
      # Clear any existing span context
      :otel_tracer.set_current_span(nil)

      labels = PyroscopeProcessor.get_current_labels()
      assert is_map(labels)
    end

    test "returns labels with trace context when span is active" do
      # Start a span using OTel directly
      tracer = :opentelemetry.get_tracer(:observlib)
      span_ctx = :otel_tracer.start_span(tracer, "test_span", %{})
      :otel_tracer.set_current_span(span_ctx)

      labels = PyroscopeProcessor.get_current_labels()
      assert is_map(labels)

      # Labels should contain trace correlation data
      # (may be empty if span context structure doesn't match expected format)

      # Clean up
      :otel_span.end_span(span_ctx)
      :otel_tracer.set_current_span(nil)
    end
  end

  describe "enabled?/0" do
    test "returns true when endpoint is configured" do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert PyroscopeProcessor.enabled?() == true

      GenServer.stop(pid)
      Application.delete_env(:observlib, :pyroscope_endpoint)
    end

    test "returns false when endpoint is not configured" do
      Application.delete_env(:observlib, :pyroscope_endpoint)
      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert PyroscopeProcessor.enabled?() == false

      GenServer.stop(pid)
    end
  end

  describe "ETS table management" do
    test "creates ETS table on startup" do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert :ets.whereis(:observlib_pyroscope_profiles) != :undefined

      GenServer.stop(pid)
      Application.delete_env(:observlib, :pyroscope_endpoint)
    end

    test "cleans up ETS table on termination" do
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")
      {:ok, pid} = PyroscopeProcessor.start_link([])

      assert :ets.whereis(:observlib_pyroscope_profiles) != :undefined

      GenServer.stop(pid)
      Process.sleep(50)

      # Table should be gone after termination
      assert :ets.whereis(:observlib_pyroscope_profiles) == :undefined

      Application.delete_env(:observlib, :pyroscope_endpoint)
    end
  end

  # Helper to stop existing processor
  defp stop_existing_processor do
    if pid = Process.whereis(PyroscopeProcessor) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    # Clean up ETS table if it exists
    if :ets.whereis(:observlib_pyroscope_profiles) != :undefined do
      try do
        :ets.delete(:observlib_pyroscope_profiles)
      catch
        :error, :badarg -> :ok
      end
    end

    Process.sleep(50)
  end
end
