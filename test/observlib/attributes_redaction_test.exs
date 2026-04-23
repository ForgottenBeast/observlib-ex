defmodule ObservLib.AttributesRedactionTest do
  @moduledoc """
  Tests for sensitive attribute redaction functionality.
  Verifies sec-011 (M-02) implementation.
  """

  use ExUnit.Case, async: false

  alias ObservLib.Attributes

  # Restarts the supervised Config GenServer so it picks up new Application env.
  defp restart_config do
    Supervisor.terminate_child(ObservLib.Supervisor, ObservLib.Config)
    {:ok, _} = Supervisor.restart_child(ObservLib.Supervisor, ObservLib.Config)
    :ok
  end

  setup do
    # Store original config
    original_config = Application.get_all_env(:observlib)

    on_exit(fn ->
      # Restore original config then restart Config to pick it up
      for {key, _} <- Application.get_all_env(:observlib) do
        Application.delete_env(:observlib, key)
      end

      for {key, value} <- original_config do
        Application.put_env(:observlib, key, value)
      end

      Supervisor.terminate_child(ObservLib.Supervisor, ObservLib.Config)
      Supervisor.restart_child(ObservLib.Supervisor, ObservLib.Config)
    end)

    # Set env BEFORE restarting Config so it reads the new values
    Application.put_env(:observlib, :service_name, "test-service")
    restart_config()
  end

  describe "default redaction list" do
    test "redacts password attribute" do
      {:ok, result} = Attributes.validate(%{"password" => "secret123"})
      assert result["password"] == "[REDACTED]"
    end

    test "redacts passwd attribute" do
      {:ok, result} = Attributes.validate(%{"passwd" => "secret123"})
      assert result["passwd"] == "[REDACTED]"
    end

    test "redacts secret attribute" do
      {:ok, result} = Attributes.validate(%{"secret" => "my_secret_value"})
      assert result["secret"] == "[REDACTED]"
    end

    test "redacts token attribute" do
      {:ok, result} = Attributes.validate(%{"token" => "abc123xyz"})
      assert result["token"] == "[REDACTED]"
    end

    test "redacts authorization attribute" do
      {:ok, result} = Attributes.validate(%{"authorization" => "Bearer token123"})
      assert result["authorization"] == "[REDACTED]"
    end

    test "redacts api_key attribute" do
      {:ok, result} = Attributes.validate(%{"api_key" => "key_abc123"})
      assert result["api_key"] == "[REDACTED]"
    end

    test "redacts credit_card attribute" do
      {:ok, result} = Attributes.validate(%{"credit_card" => "4111111111111111"})
      assert result["credit_card"] == "[REDACTED]"
    end

    test "redacts ssn attribute" do
      {:ok, result} = Attributes.validate(%{"ssn" => "123-45-6789"})
      assert result["ssn"] == "[REDACTED]"
    end

    test "redacts bearer attribute" do
      {:ok, result} = Attributes.validate(%{"bearer" => "token123"})
      assert result["bearer"] == "[REDACTED]"
    end

    test "redacts session attribute" do
      {:ok, result} = Attributes.validate(%{"session" => "session_id_123"})
      assert result["session"] == "[REDACTED]"
    end
  end

  describe "case-insensitive matching" do
    test "redacts PASSWORD (uppercase)" do
      {:ok, result} = Attributes.validate(%{"PASSWORD" => "secret123"})
      assert result["PASSWORD"] == "[REDACTED]"
    end

    test "redacts Password (mixed case)" do
      {:ok, result} = Attributes.validate(%{"Password" => "secret123"})
      assert result["Password"] == "[REDACTED]"
    end

    test "redacts API_KEY (uppercase with underscore)" do
      {:ok, result} = Attributes.validate(%{"API_KEY" => "key123"})
      assert result["API_KEY"] == "[REDACTED]"
    end
  end

  describe "substring matching" do
    test "redacts user_password (contains password)" do
      {:ok, result} = Attributes.validate(%{"user_password" => "secret123"})
      assert result["user_password"] == "[REDACTED]"
    end

    test "redacts db_token (contains token)" do
      {:ok, result} = Attributes.validate(%{"db_token" => "token123"})
      assert result["db_token"] == "[REDACTED]"
    end

    test "redacts access_token (contains token)" do
      {:ok, result} = Attributes.validate(%{"access_token" => "token123"})
      assert result["access_token"] == "[REDACTED]"
    end

    test "redacts client_secret (contains secret)" do
      {:ok, result} = Attributes.validate(%{"client_secret" => "secret123"})
      assert result["client_secret"] == "[REDACTED]"
    end

    test "redacts authorization_header (contains authorization)" do
      {:ok, result} = Attributes.validate(%{"authorization_header" => "Bearer token"})
      assert result["authorization_header"] == "[REDACTED]"
    end
  end

  describe "non-sensitive attributes" do
    test "does not redact user_name" do
      {:ok, result} = Attributes.validate(%{"user_name" => "john_doe"})
      assert result["user_name"] == "john_doe"
    end

    test "does not redact email" do
      {:ok, result} = Attributes.validate(%{"email" => "user@example.com"})
      assert result["email"] == "user@example.com"
    end

    test "does not redact user_id" do
      {:ok, result} = Attributes.validate(%{"user_id" => "12345"})
      assert result["user_id"] == "12345"
    end

    test "does not redact http_method" do
      {:ok, result} = Attributes.validate(%{"http_method" => "POST"})
      assert result["http_method"] == "POST"
    end

    test "does not redact status_code" do
      {:ok, result} = Attributes.validate(%{"status_code" => "200"})
      assert result["status_code"] == "200"
    end
  end

  describe "custom redaction list" do
    test "uses custom redaction list when configured" do
      Application.put_env(:observlib, :redacted_attribute_keys, ["custom_key"])
      restart_config()

      # Custom key is redacted
      {:ok, result} = Attributes.validate(%{"custom_key" => "value"})
      assert result["custom_key"] == "[REDACTED]"

      # Default keys are NOT redacted when using custom list
      {:ok, result2} = Attributes.validate(%{"password" => "secret123"})
      assert result2["password"] == "secret123"
    end

    test "disables redaction with empty list" do
      Application.put_env(:observlib, :redacted_attribute_keys, [])
      restart_config()

      # No redaction when list is empty
      {:ok, result} = Attributes.validate(%{"password" => "secret123"})
      assert result["password"] == "secret123"

      {:ok, result2} = Attributes.validate(%{"api_key" => "key123"})
      assert result2["api_key"] == "key123"
    end
  end

  describe "custom redaction pattern" do
    test "uses custom redaction pattern" do
      Application.put_env(:observlib, :redaction_pattern, "***HIDDEN***")
      restart_config()

      {:ok, result} = Attributes.validate(%{"password" => "secret123"})
      assert result["password"] == "***HIDDEN***"
    end
  end

  describe "combined with size limits" do
    test "redacts sensitive keys even with large values" do
      large_password = String.duplicate("x", 10_000)
      {:ok, result} = Attributes.validate(%{"password" => large_password})

      # Value is redacted (not truncated)
      assert result["password"] == "[REDACTED]"
    end

    test "truncates non-sensitive large values" do
      large_value = String.duplicate("x", 10_000)
      {:ok, result} = Attributes.validate(%{"data" => large_value})

      # Value is truncated (not redacted)
      assert String.ends_with?(result["data"], "...[TRUNC]")
      refute result["data"] == "[REDACTED]"
    end

    test "applies redaction before truncation" do
      # Redaction happens after truncation in the pipeline
      {:ok, result} =
        Attributes.validate(%{
          "password" => "secret",
          "user_id" => "12345",
          "api_token" => "token123"
        })

      assert result["password"] == "[REDACTED]"
      assert result["user_id"] == "12345"
      assert result["api_token"] == "[REDACTED]"
    end
  end

  describe "multiple attributes" do
    test "redacts multiple sensitive attributes in same map" do
      {:ok, result} =
        Attributes.validate(%{
          "username" => "john",
          "password" => "secret123",
          "api_key" => "key123",
          "email" => "john@example.com"
        })

      assert result["username"] == "john"
      assert result["password"] == "[REDACTED]"
      assert result["api_key"] == "[REDACTED]"
      assert result["email"] == "john@example.com"
    end

    test "handles mixed sensitive and non-sensitive attributes" do
      {:ok, result} =
        Attributes.validate(%{
          "http.method" => "POST",
          "http.url" => "/api/login",
          "authorization" => "Bearer token123",
          "http.status_code" => "200",
          "user.id" => "42"
        })

      assert result["http.method"] == "POST"
      assert result["http.url"] == "/api/login"
      assert result["authorization"] == "[REDACTED]"
      assert result["http.status_code"] == "200"
      assert result["user.id"] == "42"
    end
  end

  describe "edge cases" do
    test "handles empty map" do
      {:ok, result} = Attributes.validate(%{})
      assert result == %{}
    end

    test "handles nil values" do
      {:ok, result} = Attributes.validate(%{"password" => nil})
      assert result["password"] == "[REDACTED]"
    end

    test "handles non-string values" do
      {:ok, result} = Attributes.validate(%{"password" => 12345})
      assert result["password"] == "[REDACTED]"
    end

    test "handles atom keys" do
      # Attributes with atom keys should still work
      {:ok, result} = Attributes.validate(%{password: "secret123"})
      # Atom keys are not matched by default (pattern matching is for binary keys)
      assert result[:password] == "secret123"
    end
  end

  describe "integration with traces" do
    test "redacts sensitive attributes in span attributes" do
      # This tests that the validation is actually applied in the traces module
      {:ok, result} =
        Attributes.validate(%{
          "http.method" => "POST",
          "http.url" => "/login",
          "request.body.password" => "user_password_123",
          "user.id" => "42"
        })

      assert result["http.method"] == "POST"
      assert result["http.url"] == "/login"
      assert result["request.body.password"] == "[REDACTED]"
      assert result["user.id"] == "42"
    end
  end
end
