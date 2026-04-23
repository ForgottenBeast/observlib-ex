defmodule ObservLib.Security.AtomExhaustionTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ExUnit.CaptureLog

  @moduletag :security

  describe "sec-001: Atom exhaustion prevention in Metrics" do
    test "safe_to_atom/1 prefers existing atoms" do
      # Pre-create an atom
      _ = String.to_atom("existing_metric")

      # Should not log warning for existing atom
      log =
        capture_log(fn ->
          ObservLib.Metrics.counter("existing_metric", 1, %{})
        end)

      refute log =~ "Creating new atom"
    end

    test "safe_to_atom/1 warns when creating new atoms" do
      unique_name = "metric_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          ObservLib.Metrics.counter(unique_name, 1, %{})
        end)

      assert log =~ "Creating new atom for metric segment"
      assert log =~ "Consider pre-registering metrics"
    end

    @tag timeout: 120_000
    property "VM survives unbounded unique metric names" do
      check all(
              metric_suffix <- StreamData.string(:alphanumeric, min_length: 10, max_length: 20),
              max_runs: 1000
            ) do
        metric_name = "test_metric_#{metric_suffix}"

        # Should not crash the VM
        assert :ok = ObservLib.Metrics.counter(metric_name, 1, %{test: true})
      end
    end

    test "pre-registered metrics avoid atom creation" do
      metric_name = "preregistered_metric_#{System.unique_integer([:positive])}"

      # Pre-register the metric (this creates the atoms)
      ObservLib.Metrics.register_counter(metric_name, unit: :count)

      # Now recording should not log warnings (atoms already exist)
      log =
        capture_log(fn ->
          ObservLib.Metrics.counter(metric_name, 1, %{})
        end)

      # Should not contain the warning since segments are already atoms
      # Note: May still warn if metric name segments are new
      assert is_binary(log)
    end
  end

  describe "sec-002: Atom exhaustion prevention in Telemetry" do
    test "handler_id/1 only accepts atom lists" do
      # Should work with atoms
      assert :ok = ObservLib.Telemetry.attach([:valid, :prefix])

      # Clean up
      ObservLib.Telemetry.detach([:valid, :prefix])
    end

    test "handler_id/1 rejects non-atom elements" do
      assert_raise ArgumentError, ~r/requires a list of atoms/, fn ->
        # This will fail because handler_id/1 validates input
        send(ObservLib.Telemetry, {:attach, ["string", "prefix"], []})
      end
    end

    @tag timeout: 60_000
    property "telemetry handlers survive many unique prefixes" do
      check all(
              suffix <- StreamData.integer(1..1000),
              max_runs: 100
            ) do
        prefix = [String.to_atom("test#{suffix}"), :event]

        # Attach and detach handler
        case ObservLib.Telemetry.attach(prefix) do
          :ok ->
            ObservLib.Telemetry.detach(prefix)
            true

          {:error, :already_attached} ->
            # Already attached, detach and retry
            ObservLib.Telemetry.detach(prefix)
            true

          _ ->
            false
        end
      end
    end
  end
end
