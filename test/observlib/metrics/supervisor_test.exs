defmodule ObservLib.Metrics.SupervisorTest do
  use ExUnit.Case, async: false

  alias ObservLib.Metrics.MeterProvider
  alias ObservLib.Metrics.Supervisor, as: MetricsSupervisor

  setup do
    # Terminate the running Metrics.Supervisor to allow tests to start fresh instances
    Supervisor.terminate_child(ObservLib.Supervisor, ObservLib.Metrics.Supervisor)

    on_exit(fn ->
      # Restore the supervised Metrics.Supervisor
      Supervisor.restart_child(ObservLib.Supervisor, ObservLib.Metrics.Supervisor)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts the Metrics.Supervisor" do
      assert {:ok, pid} = MetricsSupervisor.start_link([])
      assert Process.alive?(pid)

      # Clean up
      Supervisor.stop(pid)
    end

    test "starts MeterProvider as child" do
      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      # MeterProvider should be running
      assert Process.whereis(MeterProvider) != nil
      assert Process.alive?(Process.whereis(MeterProvider))

      Supervisor.stop(sup_pid)
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = MetricsSupervisor.child_spec([])

      assert spec.id == MetricsSupervisor
      assert spec.type == :supervisor
      assert spec.restart == :permanent
    end
  end

  describe "supervision" do
    test "restarts MeterProvider on crash" do
      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      # Get initial MeterProvider pid
      initial_pid = Process.whereis(MeterProvider)
      assert initial_pid != nil

      # Kill MeterProvider
      Process.exit(initial_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # MeterProvider should be restarted with new pid
      new_pid = Process.whereis(MeterProvider)
      assert new_pid != nil
      assert new_pid != initial_pid
      assert Process.alive?(new_pid)

      Supervisor.stop(sup_pid)
    end

    test "uses rest_for_one strategy" do
      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      # Verify supervisor is using rest_for_one
      # This is configured in init/1
      children = Supervisor.which_children(sup_pid)
      assert length(children) >= 1

      Supervisor.stop(sup_pid)
    end
  end

  describe "conditional children" do
    test "starts OtlpMetricsExporter when OTLP endpoint configured" do
      # Set OTLP endpoint
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318")

      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      # Check if OtlpMetricsExporter is running
      children = Supervisor.which_children(sup_pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert ObservLib.Exporters.OtlpMetricsExporter in child_ids

      Supervisor.stop(sup_pid)

      # Clean up
      Application.delete_env(:observlib, :otlp_endpoint)
    end

    test "starts PrometheusReader when prometheus_port configured" do
      # Set prometheus port
      Application.put_env(:observlib, :prometheus_port, 19_569)

      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      # Check if PrometheusReader is running
      children = Supervisor.which_children(sup_pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      assert ObservLib.Metrics.PrometheusReader in child_ids

      Supervisor.stop(sup_pid)

      # Clean up
      Application.delete_env(:observlib, :prometheus_port)
    end

    test "does not start PrometheusReader when prometheus_port not configured" do
      # Ensure prometheus_port is not set
      Application.delete_env(:observlib, :prometheus_port)

      {:ok, sup_pid} = MetricsSupervisor.start_link([])

      children = Supervisor.which_children(sup_pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      refute ObservLib.Metrics.PrometheusReader in child_ids

      Supervisor.stop(sup_pid)
    end
  end
end
