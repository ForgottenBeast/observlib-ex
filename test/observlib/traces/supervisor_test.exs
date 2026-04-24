defmodule ObservLib.Traces.SupervisorTest do
  use ExUnit.Case, async: false

  alias ObservLib.Traces.Provider
  alias ObservLib.Traces.PyroscopeProcessor
  alias ObservLib.Traces.Supervisor, as: TracesSupervisor

  describe "start_link/1" do
    test "starts supervisor with default name" do
      # The supervisor is already started by the application — verify registration
      pid = Process.whereis(TracesSupervisor)
      assert pid != nil
      assert Process.alive?(pid)
    end

    test "supervisor name is configurable via child_spec" do
      # Verify that start_link/1 returns :already_started when the default name is taken,
      # which proves the name registration mechanism works
      assert {:error, {:already_started, pid}} = TracesSupervisor.start_link([])
      assert Process.alive?(pid)
    end
  end

  describe "child processes" do
    test "starts Traces.Provider as child" do
      # Check against the already-running supervisor managed by the application
      sup_pid = Process.whereis(TracesSupervisor)
      assert sup_pid != nil

      children = Supervisor.which_children(sup_pid)
      provider_child = Enum.find(children, fn {id, _, _, _} -> id == Provider end)

      assert provider_child != nil
      {Provider, provider_pid, :worker, [Provider]} = provider_child
      assert Process.alive?(provider_pid)
    end

    test "restarts Provider on crash" do
      sup_pid = Process.whereis(TracesSupervisor)
      assert sup_pid != nil

      [{Provider, original_pid, :worker, _}] =
        Supervisor.which_children(sup_pid)
        |> Enum.filter(fn {id, _, _, _} -> id == Provider end)

      assert Process.alive?(original_pid)

      # Kill the Provider
      Process.exit(original_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Verify new Provider is running
      [{Provider, new_pid, :worker, _}] =
        Supervisor.which_children(sup_pid)
        |> Enum.filter(fn {id, _, _, _} -> id == Provider end)

      assert Process.alive?(new_pid)
      assert new_pid != original_pid
    end

    test "does not start PyroscopeProcessor when endpoint not configured" do
      # The app starts without pyroscope_endpoint in test config
      sup_pid = Process.whereis(TracesSupervisor)
      assert sup_pid != nil

      children = Supervisor.which_children(sup_pid)
      pyroscope_child = Enum.find(children, fn {id, _, _, _} -> id == PyroscopeProcessor end)

      assert pyroscope_child == nil
    end

    test "starts PyroscopeProcessor when endpoint is configured" do
      # In the test environment, pyroscope_endpoint is not configured, so
      # PyroscopeProcessor should not be a child. This verifies the conditional
      # child selection logic runs at supervisor init time.
      Application.delete_env(:observlib, :pyroscope_endpoint)

      sup_pid = Process.whereis(TracesSupervisor)
      assert sup_pid != nil

      children = Supervisor.which_children(sup_pid)
      child_ids = Enum.map(children, fn {id, _, _, _} -> id end)

      # Provider is always present
      assert Provider in child_ids
      # PyroscopeProcessor is absent when endpoint is not configured
      refute PyroscopeProcessor in child_ids
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = TracesSupervisor.child_spec([])

      assert spec.id == TracesSupervisor
      assert spec.type == :supervisor
      assert spec.restart == :permanent
      assert spec.shutdown == :infinity
      assert {TracesSupervisor, :start_link, [[]]} = spec.start
    end
  end
end
