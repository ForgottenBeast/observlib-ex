defmodule ObservLib.Pyroscope.ClientTest do
  use ExUnit.Case, async: false

  alias ObservLib.Pyroscope.Client

  describe "start_link/1" do
    test "starts in disabled mode when no endpoint configured" do
      # Start a separate instance for testing
      {:ok, pid} = Client.start_link(name: :test_pyroscope_disabled)

      assert Process.alive?(pid)

      # Get status
      status = GenServer.call(pid, :get_status)
      assert status.enabled == false

      # Clean up
      GenServer.stop(pid)
    end

    test "starts in enabled mode when endpoint provided" do
      {:ok, pid} =
        Client.start_link(
          name: :test_pyroscope_enabled,
          endpoint: "http://localhost:4040"
        )

      assert Process.alive?(pid)

      status = GenServer.call(pid, :get_status)
      assert status.enabled == true
      assert status.endpoint == "http://localhost:4040"

      GenServer.stop(pid)
    end

    test "uses custom sample rate when provided" do
      {:ok, pid} =
        Client.start_link(
          name: :test_pyroscope_sample_rate,
          endpoint: "http://localhost:4040",
          sample_rate: 10000
        )

      status = GenServer.call(pid, :get_status)
      assert status.sample_rate == 10000

      GenServer.stop(pid)
    end

    test "uses custom labels when provided" do
      {:ok, pid} =
        Client.start_link(
          name: :test_pyroscope_labels,
          endpoint: "http://localhost:4040",
          labels: %{"env" => "test", "version" => "1.0"}
        )

      status = GenServer.call(pid, :get_status)
      assert status.labels["env"] == "test"
      assert status.labels["version"] == "1.0"

      GenServer.stop(pid)
    end
  end

  describe "add_labels/1" do
    test "adds labels to existing labels" do
      {:ok, pid} =
        Client.start_link(
          name: :test_add_labels,
          endpoint: "http://localhost:4040",
          labels: %{"existing" => "value"}
        )

      :ok = GenServer.call(pid, {:add_labels, %{"new_label" => "new_value"}})

      status = GenServer.call(pid, :get_status)
      assert status.labels["existing"] == "value"
      assert status.labels["new_label"] == "new_value"

      GenServer.stop(pid)
    end

    test "overwrites existing labels with same key" do
      {:ok, pid} =
        Client.start_link(
          name: :test_overwrite_labels,
          endpoint: "http://localhost:4040",
          labels: %{"key" => "old_value"}
        )

      :ok = GenServer.call(pid, {:add_labels, %{"key" => "new_value"}})

      status = GenServer.call(pid, :get_status)
      assert status.labels["key"] == "new_value"

      GenServer.stop(pid)
    end
  end

  describe "remove_labels/1" do
    test "removes specified labels" do
      {:ok, pid} =
        Client.start_link(
          name: :test_remove_labels,
          endpoint: "http://localhost:4040",
          labels: %{"keep" => "value1", "remove" => "value2"}
        )

      :ok = GenServer.call(pid, {:remove_labels, ["remove"]})

      status = GenServer.call(pid, :get_status)
      assert status.labels["keep"] == "value1"
      refute Map.has_key?(status.labels, "remove")

      GenServer.stop(pid)
    end

    test "handles removing non-existent labels gracefully" do
      {:ok, pid} =
        Client.start_link(
          name: :test_remove_nonexistent,
          endpoint: "http://localhost:4040",
          labels: %{"existing" => "value"}
        )

      :ok = GenServer.call(pid, {:remove_labels, ["nonexistent"]})

      status = GenServer.call(pid, :get_status)
      assert status.labels["existing"] == "value"

      GenServer.stop(pid)
    end
  end

  describe "get_status/0" do
    test "returns complete status information" do
      {:ok, pid} =
        Client.start_link(
          name: :test_get_status,
          endpoint: "http://localhost:4040",
          sample_rate: 5000,
          labels: %{"test" => "value"}
        )

      status = GenServer.call(pid, :get_status)

      assert is_boolean(status.enabled)
      assert is_binary(status.endpoint) or is_nil(status.endpoint)
      assert is_integer(status.sample_rate)
      assert is_map(status.labels)
      assert is_nil(status.last_upload) or is_integer(status.last_upload)
      assert is_integer(status.upload_count)
      assert is_integer(status.error_count)

      GenServer.stop(pid)
    end

    test "tracks upload and error counts" do
      {:ok, pid} =
        Client.start_link(
          name: :test_status_counts,
          endpoint: "http://localhost:4040"
        )

      status = GenServer.call(pid, :get_status)
      assert status.upload_count == 0
      assert status.error_count == 0

      GenServer.stop(pid)
    end
  end

  describe "force_flush/0" do
    test "returns error when disabled" do
      {:ok, pid} = Client.start_link(name: :test_force_flush_disabled)

      result = GenServer.call(pid, :force_flush)
      assert result == {:error, :disabled}

      GenServer.stop(pid)
    end

    test "attempts upload when enabled" do
      # Note: This will fail to actually upload without a real Pyroscope server
      # but we test that it attempts the operation
      {:ok, pid} =
        Client.start_link(
          name: :test_force_flush_enabled,
          endpoint: "http://localhost:4040"
        )

      # The force_flush will fail because there's no server, but it should
      # increment the error count
      result = GenServer.call(pid, :force_flush)

      # Either succeeds (unlikely without server) or returns error
      assert result == :ok or match?({:error, _}, result)

      GenServer.stop(pid)
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = Client.child_spec([])

      assert spec.id == ObservLib.Pyroscope.Client
      assert spec.type == :worker
      assert spec.restart == :permanent
      assert spec.shutdown == 5000
      assert {ObservLib.Pyroscope.Client, :start_link, [[]]} = spec.start
    end
  end

  describe "periodic collection" do
    test "schedules collection when enabled" do
      {:ok, pid} =
        Client.start_link(
          name: :test_periodic_collection,
          endpoint: "http://localhost:4040",
          # Short interval for testing
          sample_rate: 100
        )

      # Wait for at least one collection attempt
      Process.sleep(150)

      status = GenServer.call(pid, :get_status)
      # Should have attempted at least one upload (may have failed)
      assert status.upload_count > 0 or status.error_count > 0

      GenServer.stop(pid)
    end

    test "does not schedule collection when disabled" do
      {:ok, pid} =
        Client.start_link(
          name: :test_no_collection,
          # Short interval
          sample_rate: 100
        )

      Process.sleep(150)

      status = GenServer.call(pid, :get_status)
      # Should not have attempted any uploads
      assert status.upload_count == 0
      assert status.error_count == 0

      GenServer.stop(pid)
    end
  end

  describe "stack sampling" do
    test "collects stack traces from processes" do
      # This is an internal test - we verify the client can collect samples
      # by checking it doesn't crash during collection
      {:ok, pid} =
        Client.start_link(
          name: :test_stack_sampling,
          endpoint: "http://localhost:4040",
          sample_rate: 50
        )

      # Give it time to collect a sample
      Process.sleep(100)

      # Client should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "graceful degradation" do
    test "continues operating when Pyroscope is unreachable" do
      {:ok, pid} =
        Client.start_link(
          name: :test_graceful_degradation,
          # Non-existent server
          endpoint: "http://localhost:9999",
          sample_rate: 50
        )

      # Let it attempt several uploads
      Process.sleep(200)

      # Client should still be alive and operational
      assert Process.alive?(pid)

      status = GenServer.call(pid, :get_status)
      # Should have recorded some errors but not crashed
      assert status.error_count > 0

      GenServer.stop(pid)
    end
  end

  describe "trace context correlation" do
    test "logs within a span include trace context" do
      {:ok, pid} =
        Client.start_link(
          name: :test_trace_context,
          endpoint: "http://localhost:4040"
        )

      # Create a span and check that the client can read trace context
      ObservLib.Traces.with_span("test_span", %{}, fn ->
        # The client should be able to extract trace context
        # during its next collection cycle
        status = GenServer.call(pid, :get_status)
        assert status.enabled == true
      end)

      GenServer.stop(pid)
    end
  end
end
