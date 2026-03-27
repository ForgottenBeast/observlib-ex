defmodule ObservLibTest do
  use ExUnit.Case
  doctest ObservLib

  describe "configure/0" do
    test "returns :ok when Config GenServer is running" do
      # Config is started by the application
      assert ObservLib.configure() == :ok
    end
  end

  describe "configure/1" do
    test "accepts valid service_name" do
      assert ObservLib.configure(service_name: "test_service") == :ok
    end

    test "accepts service_name with otlp_endpoint" do
      assert ObservLib.configure(
               service_name: "test",
               otlp_endpoint: "localhost:4318"
             ) == :ok
    end

    test "accepts service_name with resource_attributes" do
      assert ObservLib.configure(
               service_name: "test",
               resource_attributes: %{"env" => "test"}
             ) == :ok
    end

    test "rejects empty service_name" do
      assert ObservLib.configure(service_name: "") == {:error, :invalid_service_name}
    end

    test "rejects non-string service_name" do
      assert ObservLib.configure(service_name: 123) == {:error, :invalid_service_name}
      assert ObservLib.configure(service_name: nil) == {:error, :invalid_service_name}
    end

    test "accepts options without service_name" do
      # When service_name is not provided, uses application config
      assert ObservLib.configure(otlp_endpoint: "localhost:4318") == :ok
    end
  end

  describe "delegation functions" do
    test "service_name/0 delegates to Config" do
      # Config is initialized with application env
      service_name = ObservLib.service_name()
      assert is_binary(service_name) or is_nil(service_name)
    end

    test "resource/0 delegates to Config and returns map" do
      resource = ObservLib.resource()
      assert is_map(resource)
      assert Map.has_key?(resource, "service.name")
    end

    test "otlp_endpoint/0 delegates to Config" do
      endpoint = ObservLib.otlp_endpoint()
      assert is_binary(endpoint) or is_nil(endpoint)
    end

    test "pyroscope_endpoint/0 delegates to Config" do
      endpoint = ObservLib.pyroscope_endpoint()
      assert is_binary(endpoint) or is_nil(endpoint)
    end
  end

  describe "integration with Config GenServer" do
    test "service_name matches Config.get_service_name" do
      assert ObservLib.service_name() == ObservLib.Config.get_service_name()
    end

    test "resource matches Config.get_resource" do
      assert ObservLib.resource() == ObservLib.Config.get_resource()
    end

    test "otlp_endpoint matches Config.get_otlp_endpoint" do
      assert ObservLib.otlp_endpoint() == ObservLib.Config.get_otlp_endpoint()
    end

    test "pyroscope_endpoint matches Config.get_pyroscope_endpoint" do
      assert ObservLib.pyroscope_endpoint() == ObservLib.Config.get_pyroscope_endpoint()
    end
  end

  describe "resource attributes" do
    test "resource always contains service.name" do
      resource = ObservLib.resource()
      assert is_binary(resource["service.name"])
      assert String.length(resource["service.name"]) > 0
    end

    test "resource contains configured attributes" do
      resource = ObservLib.resource()

      # Check for test environment attribute from config/test.exs
      assert resource["deployment.environment"] == "test"
    end
  end
end
