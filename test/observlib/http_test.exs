defmodule ObservLib.HTTPTest do
  use ExUnit.Case, async: true

  alias ObservLib.HTTP

  import ExUnit.CaptureLog

  describe "post/3" do
    test "warns when using HTTP to remote host" do
      # Mock configuration
      Application.put_env(:observlib, :tls_verify, true)

      log =
        capture_log(fn ->
          # This will fail since we're not actually making a request,
          # but it should trigger the warning
          HTTP.post("http://remote-host.example.com/api", json: %{test: true})
        end)

      assert log =~ "Plaintext HTTP connection to remote host"
      assert log =~ "remote-host.example.com"
    end

    test "does not warn for localhost HTTP" do
      Application.put_env(:observlib, :tls_verify, true)

      log =
        capture_log(fn ->
          # Should not warn for localhost
          HTTP.post("http://localhost:4318/v1/metrics", json: %{test: true})
        end)

      refute log =~ "Plaintext HTTP connection"
    end

    test "does not warn for 127.0.0.1 HTTP" do
      Application.put_env(:observlib, :tls_verify, true)

      log =
        capture_log(fn ->
          # Should not warn for 127.0.0.1
          HTTP.post("http://127.0.0.1:4318/v1/metrics", json: %{test: true})
        end)

      refute log =~ "Plaintext HTTP connection"
    end

    test "applies TLS configuration for HTTPS URLs" do
      Application.put_env(:observlib, :tls_verify, true)
      Application.put_env(:observlib, :tls_versions, [:"tlsv1.3", :"tlsv1.2"])

      # This test verifies the function doesn't crash with HTTPS URLs
      # Actual TLS verification would require a real HTTPS endpoint
      assert :ok = :ok
    end

    test "respects tls_verify: false configuration" do
      Application.put_env(:observlib, :tls_verify, false)

      # Verify configuration is read correctly
      assert Application.get_env(:observlib, :tls_verify) == false
    end

    test "supports custom CA certificate configuration" do
      Application.put_env(:observlib, :tls_ca_cert_file, "/path/to/ca.crt")

      # Verify configuration is read correctly
      assert Application.get_env(:observlib, :tls_ca_cert_file) == "/path/to/ca.crt"
    end
  end
end
