defmodule ObservLib.Logs.SupervisorTest do
  use ExUnit.Case, async: false

  describe "start_link/1" do
    test "starts the supervisor successfully" do
      # The supervisor is already started by the application
      # Verify it's running
      assert Process.whereis(ObservLib.Logs.Supervisor) != nil
    end

    test "no-op mode: children/0 is empty when no OTLP endpoint is configured" do
      # With neither otlp_logs_endpoint nor otlp_endpoint the subsystem must
      # be a no-op: no exporter POSTing at a dead default address, no backend
      # capturing events nobody consumes. Stdout logging is unaffected (the
      # default console handler is never touched).
      original_logs = Application.get_env(:observlib, :otlp_logs_endpoint)
      original = Application.get_env(:observlib, :otlp_endpoint)
      Application.delete_env(:observlib, :otlp_logs_endpoint)
      Application.delete_env(:observlib, :otlp_endpoint)

      on_exit(fn ->
        if original_logs,
          do: Application.put_env(:observlib, :otlp_logs_endpoint, original_logs),
          else: Application.delete_env(:observlib, :otlp_logs_endpoint)

        if original,
          do: Application.put_env(:observlib, :otlp_endpoint, original),
          else: Application.delete_env(:observlib, :otlp_endpoint)
      end)

      assert ObservLib.Logs.Supervisor.children() == []
    end

    test "children/0 returns exporter + backend when otlp_endpoint is set" do
      original = Application.get_env(:observlib, :otlp_endpoint)
      Application.put_env(:observlib, :otlp_endpoint, "http://localhost:4318")

      on_exit(fn ->
        if original,
          do: Application.put_env(:observlib, :otlp_endpoint, original),
          else: Application.delete_env(:observlib, :otlp_endpoint)
      end)

      child_ids =
        ObservLib.Logs.Supervisor.children()
        |> Enum.map(fn {mod, _opts} -> mod end)

      assert ObservLib.Exporters.OtlpLogsExporter in child_ids
      assert ObservLib.Logs.Backend in child_ids
    end

    test "children/0 honors the logs-specific endpoint override" do
      original = Application.get_env(:observlib, :otlp_logs_endpoint)
      Application.put_env(:observlib, :otlp_logs_endpoint, "http://localhost:4318")

      on_exit(fn ->
        if original,
          do: Application.put_env(:observlib, :otlp_logs_endpoint, original),
          else: Application.delete_env(:observlib, :otlp_logs_endpoint)
      end)

      refute ObservLib.Logs.Supervisor.children() == []
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
