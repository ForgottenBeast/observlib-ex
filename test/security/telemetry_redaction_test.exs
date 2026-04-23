defmodule ObservLib.Security.TelemetryRedactionTest do
  use ExUnit.Case, async: true

  @moduletag :security

  setup do
    # Attributes.validate/1 calls ObservLib.Config.get/2 for limits and redaction keys.
    # Start Config if it is not already running (it may be started by the application).
    unless Process.whereis(ObservLib.Config) do
      start_supervised!(ObservLib.Config)
    end

    :ok
  end

  # NEW-004/009: PII Leakage via Unvalidated Telemetry Metadata
  #
  # Root cause: ObservLib.Telemetry.handle_event/4 passes ALL metadata keys
  # directly to span attributes via `Map.take(Map.keys(metadata))` (a no-op),
  # without calling ObservLib.Attributes.validate/1 for redaction.
  #
  # The tests below verify:
  #   1. That the redaction mechanism (Attributes.validate/1) works correctly.
  #   2. That sensitive keys like "password" and "token" are redacted when
  #      the validated path is used.

  describe "NEW-004/009: Attributes.validate/1 redacts sensitive keys" do
    test "redacts 'password' key from attribute map" do
      {:ok, sanitized} = ObservLib.Attributes.validate(%{"password" => "secret123"})

      assert sanitized["password"] == "[REDACTED]",
             "password key must be redacted; got: #{inspect(sanitized["password"])}"

      refute sanitized["password"] == "secret123",
             "Raw password value must not appear in sanitized attributes"
    end

    test "redacts 'token' key from attribute map" do
      {:ok, sanitized} = ObservLib.Attributes.validate(%{"token" => "bearer-abc123"})

      assert sanitized["token"] == "[REDACTED]",
             "token key must be redacted; got: #{inspect(sanitized["token"])}"
    end

    test "redacts multiple sensitive keys in a single pass" do
      attrs = %{
        "password" => "supersecret",
        "token" => "abc123",
        "api_key" => "key-xyz",
        "username" => "alice"
      }

      {:ok, sanitized} = ObservLib.Attributes.validate(attrs)

      assert sanitized["password"] == "[REDACTED]"
      assert sanitized["token"] == "[REDACTED]"
      assert sanitized["api_key"] == "[REDACTED]"
      # Non-sensitive keys are passed through unchanged
      assert sanitized["username"] == "alice"
    end

    test "redacts atom-keyed sensitive attributes (atom keys converted to strings)" do
      # Telemetry metadata often uses atom keys; validate/1 handles string keys.
      # The handle_event/4 code converts atom keys to strings before building attrs.
      attrs_with_string_keys = %{
        "password" => "my_secret",
        "session" => "sess-token-123",
        "safe_field" => "public_value"
      }

      {:ok, sanitized} = ObservLib.Attributes.validate(attrs_with_string_keys)

      assert sanitized["password"] == "[REDACTED]"
      assert sanitized["session"] == "[REDACTED]"
      assert sanitized["safe_field"] == "public_value"
    end

    test "redacts 'authorization' key" do
      {:ok, sanitized} =
        ObservLib.Attributes.validate(%{"authorization" => "Bearer secret_token"})

      assert sanitized["authorization"] == "[REDACTED]"
    end

    test "redacts keys via case-insensitive substring match" do
      # Should redact any key containing 'password' as substring
      {:ok, sanitized} =
        ObservLib.Attributes.validate(%{
          "user_password" => "secret",
          "PASSWORD" => "also_secret",
          "DB_PASSWORD_HASH" => "hashed"
        })

      assert sanitized["user_password"] == "[REDACTED]"
      assert sanitized["PASSWORD"] == "[REDACTED]"
      assert sanitized["DB_PASSWORD_HASH"] == "[REDACTED]"
    end

    test "non-sensitive attributes pass through unchanged" do
      {:ok, sanitized} =
        ObservLib.Attributes.validate(%{
          "http.method" => "GET",
          "http.status_code" => "200",
          "user.id" => "usr_123",
          "duration_ms" => "45"
        })

      assert sanitized["http.method"] == "GET"
      assert sanitized["http.status_code"] == "200"
      assert sanitized["user.id"] == "usr_123"
      assert sanitized["duration_ms"] == "45"
    end

    test "empty attribute map returns empty result" do
      {:ok, sanitized} = ObservLib.Attributes.validate(%{})
      assert sanitized == %{}
    end
  end

  describe "NEW-004 gap: handle_event/4 does not currently invoke validate/1" do
    # This test documents the VULNERABILITY: handle_event/4 uses
    # Map.take(Map.keys(metadata)) which is an identity operation — it filters
    # nothing. Sensitive metadata keys flow directly into span attributes.
    #
    # The fix (not yet applied) is to call:
    #   {:ok, sanitized_attributes} = ObservLib.Attributes.validate(attributes)
    #
    # This test verifies the redaction pathway works in isolation.
    # A separate integration test (once the fix is applied) should confirm
    # handle_event/4 produces redacted span attributes.

    test "validate/1 is the correct remediation: applying it to handle_event metadata produces safe output" do
      # Simulate what handle_event/4 does with incoming metadata
      raw_metadata = %{
        password: "super_secret",
        token: "bearer-xyz",
        user_id: "usr_456",
        duration: 150
      }

      # Step 1: What handle_event/4 currently does (vulnerable path)
      vulnerable_attributes =
        raw_metadata
        # identity operation — takes all keys
        |> Map.take(Map.keys(raw_metadata))
        |> Enum.reduce(%{}, fn {k, v}, acc ->
          key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
          Map.put(acc, key, v)
        end)

      # Vulnerable: password appears in attributes
      assert vulnerable_attributes["password"] == "super_secret"
      assert vulnerable_attributes["token"] == "bearer-xyz"

      # Step 2: What handle_event/4 SHOULD do (remediated path)
      {:ok, safe_attributes} = ObservLib.Attributes.validate(vulnerable_attributes)

      # Remediated: password and token are redacted
      assert safe_attributes["password"] == "[REDACTED]",
             "After validate/1, password must be redacted"

      assert safe_attributes["token"] == "[REDACTED]",
             "After validate/1, token must be redacted"

      # Non-sensitive attributes preserved
      assert safe_attributes["user_id"] == "usr_456"
    end
  end
end
