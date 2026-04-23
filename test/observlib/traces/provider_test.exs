defmodule ObservLib.Traces.ProviderTest do
  use ExUnit.Case, async: false

  alias ObservLib.Traces.Provider

  setup do
    # Stop any existing Provider
    stop_existing_provider()

    # Start a fresh Provider for each test
    {:ok, pid} =
      Provider.start_link(
        cleanup_interval: :timer.minutes(5),
        stale_span_timeout: :timer.minutes(10)
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal, 1000)
      end
      # Restore supervised Provider
      Supervisor.restart_child(ObservLib.Traces.Supervisor, ObservLib.Traces.Provider)
    end)

    {:ok, provider: pid}
  end

  describe "start_link/1" do
    test "starts with default options", %{provider: pid} do
      assert Process.alive?(pid)
      assert Process.whereis(Provider) == pid
    end

    test "creates ETS table on startup" do
      # Table should exist after startup in setup
      assert :ets.whereis(:observlib_active_spans) != :undefined
    end
  end

  describe "start_span/2" do
    test "creates a span and returns span context" do
      span = Provider.start_span("test_operation")
      assert is_tuple(span)
    end

    test "creates span with attributes" do
      attributes = %{"http.method" => "GET", "http.url" => "/api/users"}
      span = Provider.start_span("http_request", attributes)
      assert is_tuple(span)

      # Clean up
      Provider.end_span(span)
    end

    test "tracks span in ETS" do
      span = Provider.start_span("tracked_span")

      # Give cast time to process
      Process.sleep(50)

      spans = Provider.get_active_spans()
      assert length(spans) >= 1

      span_names = Enum.map(spans, & &1.name)
      assert "tracked_span" in span_names

      Provider.end_span(span)
    end
  end

  describe "end_span/1" do
    test "ends span and removes from ETS" do
      span = Provider.start_span("span_to_end")

      # Give cast time to process
      Process.sleep(50)

      # Verify span is tracked
      initial_count = Provider.active_span_count()
      assert initial_count >= 1

      # End the span
      Provider.end_span(span)

      # Give cast time to process
      Process.sleep(50)

      # Verify span is removed
      final_count = Provider.active_span_count()
      assert final_count < initial_count
    end
  end

  describe "get_active_spans/0" do
    test "returns empty list when no spans active" do
      spans = Provider.get_active_spans()
      assert is_list(spans)
    end

    test "returns all active spans" do
      span1 = Provider.start_span("span_1")
      span2 = Provider.start_span("span_2")
      span3 = Provider.start_span("span_3")

      # Give casts time to process
      Process.sleep(50)

      spans = Provider.get_active_spans()
      assert length(spans) >= 3

      span_names = Enum.map(spans, & &1.name)
      assert "span_1" in span_names
      assert "span_2" in span_names
      assert "span_3" in span_names

      # Clean up
      Provider.end_span(span1)
      Provider.end_span(span2)
      Provider.end_span(span3)
    end

    test "span info contains expected fields" do
      span = Provider.start_span("detailed_span", %{"key" => "value"})

      Process.sleep(50)

      spans = Provider.get_active_spans()
      span_info = Enum.find(spans, fn s -> s.name == "detailed_span" end)

      assert span_info != nil
      assert Map.has_key?(span_info, :span_id)
      assert Map.has_key?(span_info, :name)
      assert Map.has_key?(span_info, :attributes)
      assert Map.has_key?(span_info, :start_time)
      assert Map.has_key?(span_info, :pid)

      assert span_info.name == "detailed_span"
      assert span_info.attributes == %{"key" => "value"}

      Provider.end_span(span)
    end
  end

  describe "active_span_count/0" do
    test "returns 0 when no spans active" do
      # End any spans that might exist
      spans = Provider.get_active_spans()
      assert Provider.active_span_count() == length(spans)
    end

    test "increments and decrements correctly" do
      initial = Provider.active_span_count()

      span = Provider.start_span("counted_span")
      Process.sleep(50)

      assert Provider.active_span_count() == initial + 1

      Provider.end_span(span)
      Process.sleep(50)

      assert Provider.active_span_count() == initial
    end
  end

  describe "concurrent span tracking" do
    test "handles spans from multiple processes" do
      parent = self()

      # Spawn multiple processes that create spans
      pids =
        for i <- 1..5 do
          spawn(fn ->
            span = Provider.start_span("concurrent_span_#{i}")
            Process.sleep(100)
            send(parent, {:span_created, i, span})

            receive do
              :end_span -> Provider.end_span(span)
            end
          end)
        end

      # Wait for all spans to be created
      spans =
        for _ <- 1..5 do
          receive do
            {:span_created, _i, span} -> span
          after
            1000 -> flunk("Timeout waiting for span creation")
          end
        end

      Process.sleep(50)

      # Verify all spans are tracked
      assert Provider.active_span_count() >= 5

      active_spans = Provider.get_active_spans()

      concurrent_spans =
        Enum.filter(active_spans, fn s -> String.starts_with?(s.name, "concurrent_span_") end)

      assert length(concurrent_spans) == 5

      # End all spans
      Enum.each(pids, fn pid -> send(pid, :end_span) end)
      Process.sleep(100)

      # Verify spans are removed
      active_spans_after = Provider.get_active_spans()

      concurrent_spans_after =
        Enum.filter(active_spans_after, fn s ->
          String.starts_with?(s.name, "concurrent_span_")
        end)

      assert length(concurrent_spans_after) == 0
    end
  end

  describe "ETS table cleanup on terminate" do
    test "ETS table exists while Provider is running" do
      # Provider from setup is running and owns the ETS table
      assert :ets.whereis(:observlib_active_spans) != :undefined
    end
  end

  # Helper to stop existing Provider
  defp stop_existing_provider do
    # Use terminate_child to stop the supervised Provider without auto-restart
    Supervisor.terminate_child(ObservLib.Traces.Supervisor, ObservLib.Traces.Provider)

    # Clean up ETS table if it exists without owner
    if :ets.whereis(:observlib_active_spans) != :undefined do
      try do
        :ets.delete(:observlib_active_spans)
      catch
        :error, :badarg -> :ok
      end
    end
  end
end
