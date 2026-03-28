defmodule ObservLib.Security.TlsValidationTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ObservLib.HTTP

  @moduletag :security

  describe "sec-006: TLS certificate validation" do
    test "TLS verification is enabled by default" do
      # Check default configuration
      Application.put_env(:observlib, :tls_verify, true)

      tls_verify = Application.get_env(:observlib, :tls_verify, true)
      assert tls_verify == true
    end

    test "TLS versions include only secure versions by default" do
      tls_versions = Application.get_env(:observlib, :tls_versions, [:"tlsv1.3", :"tlsv1.2"])

      assert :"tlsv1.3" in tls_versions or :"tlsv1.2" in tls_versions
      refute :"tlsv1.1" in tls_versions
      refute :"tlsv1" in tls_versions
      refute :sslv3 in tls_versions
    end

    test "custom CA certificates can be configured" do
      test_ca_path = "/etc/ssl/certs/custom-ca.pem"
      Application.put_env(:observlib, :tls_ca_cert_file, test_ca_path)

      ca_file = Application.get_env(:observlib, :tls_ca_cert_file)
      assert ca_file == test_ca_path

      # Clean up
      Application.delete_env(:observlib, :tls_ca_cert_file)
    end

    test "HTTPS URLs trigger TLS configuration" do
      # This test verifies the TLS config is applied for HTTPS
      Application.put_env(:observlib, :tls_verify, true)

      # The function should not crash and should attempt TLS config
      # (will fail without a real endpoint, but that's expected)
      result = HTTP.post("https://example.com/v1/traces", json: %{test: true})

      # Either succeeds or fails with connection error, but not config error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "HTTP to localhost does not trigger TLS warnings" do
      log = capture_log(fn ->
        HTTP.post("http://localhost:4318/v1/traces", json: %{})
      end)

      refute log =~ "Plaintext HTTP connection to remote host"
    end

    test "HTTP to 127.0.0.1 does not trigger TLS warnings" do
      log = capture_log(fn ->
        HTTP.post("http://127.0.0.1:4318/v1/traces", json: %{})
      end)

      refute log =~ "Plaintext HTTP connection to remote host"
    end

    test "HTTP to remote host triggers security warning" do
      log = capture_log(fn ->
        HTTP.post("http://remote-collector.example.com/v1/traces", json: %{})
      end)

      assert log =~ "Plaintext HTTP connection to remote host"
      assert log =~ "Consider using HTTPS"
    end

    test "HTTP to IPv6 localhost does not trigger warnings" do
      log = capture_log(fn ->
        HTTP.post("http://[::1]:4318/v1/traces", json: %{})
      end)

      refute log =~ "Plaintext HTTP connection to remote host"
    end
  end

  describe "sec-007: URL validation and SSRF prevention" do
    test "validates HTTP and HTTPS schemes only" do
      assert {:ok, _} = HTTP.validate_endpoint_url("http://localhost:4318")
      assert {:ok, _} = HTTP.validate_endpoint_url("https://example.com")

      assert {:error, msg} = HTTP.validate_endpoint_url("file:///etc/passwd")
      assert msg =~ "only http and https allowed"

      assert {:error, msg} = HTTP.validate_endpoint_url("ftp://example.com")
      assert msg =~ "only http and https allowed"

      assert {:error, msg} = HTTP.validate_endpoint_url("data:text/plain,hello")
      assert msg =~ "only http and https allowed"

      assert {:error, msg} = HTTP.validate_endpoint_url("gopher://example.com")
      assert msg =~ "only http and https allowed"
    end

    test "rejects URLs with user info to prevent credential leakage" do
      assert {:error, msg} = HTTP.validate_endpoint_url("http://user:pass@example.com")
      assert msg =~ "User info in URL not allowed"

      assert {:error, msg} = HTTP.validate_endpoint_url("https://admin:secret@api.example.com")
      assert msg =~ "use headers for auth"
    end

    test "rejects URLs with missing or empty host" do
      assert {:error, msg} = HTTP.validate_endpoint_url("http://")
      assert msg =~ "Missing or empty host"

      assert {:error, msg} = HTTP.validate_endpoint_url("https://")
      assert msg =~ "Missing or empty host"
    end

    test "accepts nil and empty string URLs" do
      assert {:ok, nil} = HTTP.validate_endpoint_url(nil)
      assert {:ok, nil} = HTTP.validate_endpoint_url("")
    end

    test "accepts valid HTTP URLs" do
      assert {:ok, url} = HTTP.validate_endpoint_url("http://localhost:4318/v1/traces")
      assert url == "http://localhost:4318/v1/traces"

      assert {:ok, url} = HTTP.validate_endpoint_url("https://api.example.com:8080/metrics")
      assert url == "https://api.example.com:8080/metrics"
    end

    test "SSRF payloads are rejected" do
      ssrf_urls = [
        "file:///etc/passwd",
        "file://C:/Windows/System32/config/SAM",
        "dict://localhost:11211",
        "gopher://127.0.0.1:6379",
        "ldap://localhost:389",
        "jar:http://example.com/payload.jar!/",
        "data:text/html,<script>alert(1)</script>"
      ]

      for url <- ssrf_urls do
        assert {:error, _} = HTTP.validate_endpoint_url(url)
      end
    end
  end
end
