defmodule ObservLib.Traces.SupervisorTest do
  use ExUnit.Case, async: false

  alias ObservLib.Traces.Supervisor, as: TracesSupervisor
  alias ObservLib.Traces.Provider
  alias ObservLib.Traces.PyroscopeProcessor

  setup do
    # Ensure clean state before each test
    on_exit(fn ->
      # Clean up any leftover processes
      if pid = Process.whereis(TracesSupervisor) do
        try do
          Supervisor.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts supervisor with default name" do
      # Stop existing supervisor if running under Application
      stop_existing_supervisor()

      {:ok, pid} = TracesSupervisor.start_link([])
      assert Process.alive?(pid)
      assert Process.whereis(TracesSupervisor) == pid

      Supervisor.stop(pid)
    end

    test "starts supervisor with custom name" do
      {:ok, pid} = TracesSupervisor.start_link(name: :custom_traces_supervisor)
      assert Process.alive?(pid)
      assert Process.whereis(:custom_traces_supervisor) == pid

      Supervisor.stop(pid)
    end
  end

  describe "child processes" do
    test "starts Traces.Provider as child" do
      stop_existing_supervisor()

      {:ok, sup_pid} = TracesSupervisor.start_link([])

      # Verify Provider is running
      children = Supervisor.which_children(sup_pid)
      provider_child = Enum.find(children, fn {id, _, _, _} -> id == Provider end)

      assert provider_child != nil
      {Provider, provider_pid, :worker, [Provider]} = provider_child
      assert Process.alive?(provider_pid)

      Supervisor.stop(sup_pid)
    end

    test "restarts Provider on crash" do
      stop_existing_supervisor()

      {:ok, sup_pid} = TracesSupervisor.start_link([])

      # Get current Provider pid
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

      Supervisor.stop(sup_pid)
    end

    test "does not start PyroscopeProcessor when endpoint not configured" do
      stop_existing_supervisor()

      # Ensure pyroscope_endpoint is not set
      Application.delete_env(:observlib, :pyroscope_endpoint)

      {:ok, sup_pid} = TracesSupervisor.start_link([])

      children = Supervisor.which_children(sup_pid)
      pyroscope_child = Enum.find(children, fn {id, _, _, _} -> id == PyroscopeProcessor end)

      assert pyroscope_child == nil

      Supervisor.stop(sup_pid)
    end

    test "starts PyroscopeProcessor when endpoint is configured" do
      stop_existing_supervisor()

      # Set pyroscope_endpoint
      Application.put_env(:observlib, :pyroscope_endpoint, "http://localhost:4040")

      {:ok, sup_pid} = TracesSupervisor.start_link([])

      children = Supervisor.which_children(sup_pid)
      pyroscope_child = Enum.find(children, fn {id, _, _, _} -> id == PyroscopeProcessor end)

      assert pyroscope_child != nil

      # Clean up
      Supervisor.stop(sup_pid)
      Application.delete_env(:observlib, :pyroscope_endpoint)
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

  # Helper to stop existing supervisor started by Application
  defp stop_existing_supervisor do
    if pid = Process.whereis(TracesSupervisor) do
      try do
        Supervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    # Also stop Provider if running standalone
    if pid = Process.whereis(Provider) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    Process.sleep(50)
  end
end
