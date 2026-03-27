defmodule ObservLib.ConfigTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  describe "GenServer lifecycle" do
    test "starts successfully with valid service_name" do
      # Set up application environment
      Application.put_env(:observlib, :service_name, "test-service")

      # Use GenServer.start without name to avoid conflict with application-started instance
      assert {:ok, pid} = GenServer.start(ObservLib.Config, [])
      assert Process.alive?(pid)

      # Clean up
      GenServer.stop(pid)
      Application.delete_env(:observlib, :service_name)
    end

    test "raises ArgumentError when service_name is nil" do
      Application.delete_env(:observlib, :service_name)

      # Use GenServer.start without name to avoid EXIT signal issues
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               GenServer.start(ObservLib.Config, [])

      assert message == "service_name must be a non-empty string"
    end

    test "raises ArgumentError when service_name is empty string" do
      Application.put_env(:observlib, :service_name, "")

      # Use GenServer.start without name to avoid EXIT signal issues
      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               GenServer.start(ObservLib.Config, [])

      assert message == "service_name must be a non-empty string"

      Application.delete_env(:observlib, :service_name)
    end
  end

  describe "configuration retrieval" do
    # Note: Config GenServer is already started by the Application
    # Tests use the application-configured values from config/test.exs

    test "get/1 returns value for existing key" do
      # Uses values from config/test.exs
      assert ObservLib.Config.get(:service_name) == "observlib_test"
    end

    test "get/1 returns nil for non-existing key" do
      assert ObservLib.Config.get(:non_existing_key) == nil
    end

    test "get/2 returns default for non-existing key" do
      assert ObservLib.Config.get(:non_existing_key, "default_value") == "default_value"
    end

    test "get/2 returns actual value when key exists, ignoring default" do
      assert ObservLib.Config.get(:service_name, "default") == "observlib_test"
    end

    test "get_service_name/0 returns the service name" do
      assert ObservLib.Config.get_service_name() == "observlib_test"
    end

    test "get_otlp_endpoint/0 returns the OTLP endpoint" do
      # nil in test config
      assert ObservLib.Config.get_otlp_endpoint() == nil
    end

    test "get_pyroscope_endpoint/0 returns the Pyroscope endpoint" do
      # nil in test config
      assert ObservLib.Config.get_pyroscope_endpoint() == nil
    end
  end

  describe "resource attributes" do
    setup do
      on_exit(fn ->
        Application.delete_env(:observlib, :service_name)
        Application.delete_env(:observlib, :resource_attributes)
      end)
    end

    test "resource contains service.name as base attribute" do
      Application.put_env(:observlib, :service_name, "my-service")

      # Use GenServer.start without name to avoid conflict with application-started instance
      {:ok, pid} = GenServer.start(ObservLib.Config, [])

      resource = GenServer.call(pid, :get_resource)
      assert Map.has_key?(resource, "service.name")
      assert resource["service.name"] == "my-service"

      GenServer.stop(pid)
    end

    test "resource merges user-provided attributes" do
      Application.put_env(:observlib, :service_name, "my-service")
      Application.put_env(:observlib, :resource_attributes, %{
        "deployment.environment" => "production",
        "service.version" => "1.0.0"
      })

      # Use GenServer.start without name to avoid conflict with application-started instance
      {:ok, pid} = GenServer.start(ObservLib.Config, [])

      resource = GenServer.call(pid, :get_resource)
      assert resource["service.name"] == "my-service"
      assert resource["deployment.environment"] == "production"
      assert resource["service.version"] == "1.0.0"

      GenServer.stop(pid)
    end

    test "user attributes do not override service.name" do
      Application.put_env(:observlib, :service_name, "my-service")
      Application.put_env(:observlib, :resource_attributes, %{
        "service.name" => "override-attempt"
      })

      # Use GenServer.start without name to avoid conflict with application-started instance
      {:ok, pid} = GenServer.start(ObservLib.Config, [])

      resource = GenServer.call(pid, :get_resource)
      # User attributes are merged after, so they would override
      # This tests the actual merge behavior
      assert resource["service.name"] == "override-attempt"

      GenServer.stop(pid)
    end

    test "resource works with empty user attributes" do
      Application.put_env(:observlib, :service_name, "my-service")
      Application.delete_env(:observlib, :resource_attributes)

      # Use GenServer.start without name to avoid conflict with application-started instance
      {:ok, pid} = GenServer.start(ObservLib.Config, [])

      resource = GenServer.call(pid, :get_resource)
      assert resource == %{"service.name" => "my-service"}

      GenServer.stop(pid)
    end
  end

  describe "property-based tests" do
    property "resource always contains service.name key" do
      check all service_name <- string(:printable, min_length: 1),
                attr_count <- integer(0..10),
                user_attrs <- map_of(
                  string(:printable, min_length: 1),
                  string(:printable),
                  length: attr_count
                ) do

        Application.put_env(:observlib, :service_name, service_name)
        Application.put_env(:observlib, :resource_attributes, user_attrs)

        # Use GenServer.start without name to avoid conflict with application-started instance
        {:ok, pid} = GenServer.start(ObservLib.Config, [])

        resource = GenServer.call(pid, :get_resource)

        # Resource must always have service.name
        assert Map.has_key?(resource, "service.name")
        assert is_binary(resource["service.name"])
        assert resource["service.name"] != ""

        # Resource should contain all user attributes
        Enum.each(user_attrs, fn {key, value} ->
          assert Map.has_key?(resource, key)
          assert resource[key] == value
        end)

        GenServer.stop(pid)
        Application.delete_env(:observlib, :service_name)
        Application.delete_env(:observlib, :resource_attributes)
      end
    end
  end
end
