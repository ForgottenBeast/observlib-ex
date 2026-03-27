defmodule ObservLib.Logs.SupervisorTest do
  use ExUnit.Case, async: false

  describe "start_link/1" do
    test "starts the supervisor successfully" do
      # The supervisor is already started by the application
      # Verify it's running
      assert Process.whereis(ObservLib.Logs.Supervisor) != nil
    end

    test "supervisor has correct children" do
      children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      # Should have OtlpLogsExporter and Logs.Backend
      child_ids = Enum.map(children, fn {id, _pid, _type, _modules} -> id end)

      assert ObservLib.Exporters.OtlpLogsExporter in child_ids
      assert ObservLib.Logs.Backend in child_ids
    end

    test "children are running" do
      children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      for {_id, pid, _type, _modules} <- children do
        assert is_pid(pid)
        assert Process.alive?(pid)
      end
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = ObservLib.Logs.Supervisor.child_spec([])

      assert spec.id == ObservLib.Logs.Supervisor
      assert spec.type == :supervisor
      assert spec.restart == :permanent
      assert spec.shutdown == :infinity
      assert {ObservLib.Logs.Supervisor, :start_link, [[]]} = spec.start
    end
  end

  describe "supervision" do
    test "restarts OtlpLogsExporter on crash" do
      # Get the current exporter PID
      children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      {_, exporter_pid, _, _} =
        Enum.find(children, fn {id, _, _, _} -> id == ObservLib.Exporters.OtlpLogsExporter end)

      assert is_pid(exporter_pid)
      assert Process.alive?(exporter_pid)

      # Kill the exporter
      Process.exit(exporter_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Verify it was restarted with a new PID
      new_children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      {_, new_exporter_pid, _, _} =
        Enum.find(new_children, fn {id, _, _, _} -> id == ObservLib.Exporters.OtlpLogsExporter end)

      assert is_pid(new_exporter_pid)
      assert Process.alive?(new_exporter_pid)
      assert new_exporter_pid != exporter_pid
    end

    test "restarts Backend on crash" do
      # Get the current backend PID
      children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      {_, backend_pid, _, _} =
        Enum.find(children, fn {id, _, _, _} -> id == ObservLib.Logs.Backend end)

      assert is_pid(backend_pid)
      assert Process.alive?(backend_pid)

      # Kill the backend
      Process.exit(backend_pid, :kill)

      # Wait for restart
      Process.sleep(100)

      # Verify it was restarted with a new PID
      new_children = Supervisor.which_children(ObservLib.Logs.Supervisor)

      {_, new_backend_pid, _, _} =
        Enum.find(new_children, fn {id, _, _, _} -> id == ObservLib.Logs.Backend end)

      assert is_pid(new_backend_pid)
      assert Process.alive?(new_backend_pid)
      assert new_backend_pid != backend_pid
    end
  end
end
