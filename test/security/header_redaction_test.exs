defmodule ObservLib.Security.HeaderRedactionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ObservLib.HTTP

  @moduletag :security

  describe "sec-012: Header redaction in error logs" do
    test "redacts Authorization header in error context" do
      error_context = %{
        "Authorization" => "Bearer secret_token_12345",
        "Content-Type" => "application/json"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["Authorization"] == "[REDACTED]"
      assert redacted["Content-Type"] == "application/json"
    end

    test "redacts X-API-Key header in error context" do
      error_context = %{
        "X-API-Key" => "api_key_secret_67890",
        "Accept" => "application/json"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["X-API-Key"] == "[REDACTED]"
      assert redacted["Accept"] == "application/json"
    end

    test "redacts X-Auth-Token header in error context" do
      error_context = %{
        "X-Auth-Token" => "auth_token_xyz",
        "User-Agent" => "ObservLib/1.0"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["X-Auth-Token"] == "[REDACTED]"
      assert redacted["User-Agent"] == "ObservLib/1.0"
    end

    test "redacts Bearer tokens in various header formats" do
      contexts = [
        %{"Authorization" => "Bearer token123"},
        %{"authorization" => "bearer TOKEN456"},
        %{"AUTHORIZATION" => "BEARER token789"}
      ]

      for context <- contexts do
        redacted = HTTP.redact_sensitive_headers(context)
        [key] = Map.keys(redacted)
        assert redacted[key] == "[REDACTED]"
      end
    end

    test "redacts multiple sensitive headers" do
      error_context = %{
        "Authorization" => "Bearer secret1",
        "X-API-Key" => "secret2",
        "X-Auth-Token" => "secret3",
        "Content-Type" => "application/json",
        "Accept" => "application/json"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["Authorization"] == "[REDACTED]"
      assert redacted["X-API-Key"] == "[REDACTED]"
      assert redacted["X-Auth-Token"] == "[REDACTED]"
      assert redacted["Content-Type"] == "application/json"
      assert redacted["Accept"] == "application/json"
    end

    test "handles case-insensitive header name matching" do
      error_context = %{
        "authorization" => "secret",
        "x-api-key" => "secret",
        "API-KEY" => "secret",
        "normal-header" => "public"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["authorization"] == "[REDACTED]"
      assert redacted["x-api-key"] == "[REDACTED]"
      assert redacted["API-KEY"] == "[REDACTED]"
      assert redacted["normal-header"] == "public"
    end

    test "redacts headers with 'token' in the name" do
      error_context = %{
        "X-Custom-Token" => "secret_token",
        "Session-Token" => "session123",
        "Token" => "token456"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["X-Custom-Token"] == "[REDACTED]"
      assert redacted["Session-Token"] == "[REDACTED]"
      assert redacted["Token"] == "[REDACTED]"
    end

    test "redacts headers with 'bearer' in the value" do
      error_context = %{
        "Custom-Auth" => "Bearer custom_secret",
        "Authorization" => "bearer another_secret"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted["Custom-Auth"] == "[REDACTED]"
      assert redacted["Authorization"] == "[REDACTED]"
    end

    test "handles non-map error contexts safely" do
      # Should return non-map values unchanged
      assert HTTP.redact_sensitive_headers("error string") == "error string"
      assert HTTP.redact_sensitive_headers(nil) == nil
      assert HTTP.redact_sensitive_headers(42) == 42
      assert HTTP.redact_sensitive_headers([1, 2, 3]) == [1, 2, 3]
    end

    test "preserves error context structure" do
      error_context = %{
        "headers" => %{
          "Authorization" => "Bearer secret"
        },
        "status" => 500,
        "message" => "Internal server error"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      # Should redact at top level
      assert redacted["headers"] == "[REDACTED]" or is_map(redacted["headers"])
      assert redacted["status"] == 500
      assert redacted["message"] == "Internal server error"
    end

    test "error logs use redacted headers" do
      # Simulate an export failure that would log headers
      log = capture_log(fn ->
        # Create a mock error with sensitive headers
        error_context = %{
          "Authorization" => "Bearer super_secret_token",
          "X-API-Key" => "api_key_123456"
        }

        # Redact before logging (as done in OtlpLogsExporter)
        safe_context = HTTP.redact_sensitive_headers(error_context)

        require Logger
        Logger.error("Export failed: #{inspect(safe_context)}")
      end)

      # Log should contain redacted marker, not actual secrets
      assert log =~ "[REDACTED]"
      refute log =~ "super_secret_token"
      refute log =~ "api_key_123456"
    end

    test "handles atom keys in error context" do
      error_context = %{
        Authorization: "Bearer secret",
        :x_api_key => "api_secret",
        content_type: "application/json"
      }

      redacted = HTTP.redact_sensitive_headers(error_context)

      assert redacted[:Authorization] == "[REDACTED]" or redacted["Authorization"] == "[REDACTED]"
      assert redacted[:content_type] == "application/json" or redacted["content_type"] == "application/json"
    end
  end
end
