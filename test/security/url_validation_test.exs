defmodule ObservLib.Security.UrlValidationTest do
  use ExUnit.Case, async: true

  alias ObservLib.HTTP

  @moduletag :security

  describe "sec-007: URL validation and SSRF prevention" do
    test "accepts valid HTTP URLs" do
      valid_urls = [
        "http://localhost:4318/v1/traces",
        "http://127.0.0.1:4318/v1/metrics",
        "http://example.com/api/logs",
        "http://api.example.com:8080/endpoint",
        "http://192.168.1.1:9411/api/v2/spans"
      ]

      for url <- valid_urls do
        assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
      end
    end

    test "accepts valid HTTPS URLs" do
      valid_urls = [
        "https://api.example.com/v1/traces",
        "https://collector.example.com:443/metrics",
        "https://example.com/logs",
        "https://otel.example.com/v1/spans"
      ]

      for url <- valid_urls do
        assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
      end
    end

    test "rejects file:// URLs (local file access)" do
      file_urls = [
        "file:///etc/passwd",
        "file://C:/Windows/System32/config/SAM",
        "file:///home/user/.ssh/id_rsa",
        "file://localhost/etc/shadow"
      ]

      for url <- file_urls do
        assert {:error, msg} = HTTP.validate_endpoint_url(url)
        assert msg =~ "Invalid scheme"
        assert msg =~ "only http and https allowed"
      end
    end

    test "rejects ftp:// URLs" do
      assert {:error, msg} = HTTP.validate_endpoint_url("ftp://ftp.example.com/file.txt")
      assert msg =~ "Invalid scheme"
      assert msg =~ "only http and https allowed"
    end

    test "rejects data:// URLs (data URI injection)" do
      data_urls = [
        "data:text/plain,hello",
        "data:text/html,<script>alert(1)</script>",
        "data:application/json,{\"key\":\"value\"}"
      ]

      for url <- data_urls do
        assert {:error, msg} = HTTP.validate_endpoint_url(url)
        assert msg =~ "Invalid scheme"
      end
    end

    test "rejects gopher:// URLs (gopher protocol injection)" do
      assert {:error, msg} = HTTP.validate_endpoint_url("gopher://127.0.0.1:6379/_GET%20key")
      assert msg =~ "Invalid scheme"
    end

    test "rejects dict:// URLs (dict protocol injection)" do
      assert {:error, msg} = HTTP.validate_endpoint_url("dict://localhost:11211/get:key")
      assert msg =~ "Invalid scheme"
    end

    test "rejects ldap:// URLs (LDAP injection)" do
      assert {:error, msg} = HTTP.validate_endpoint_url("ldap://localhost:389/dc=example,dc=com")
      assert msg =~ "Invalid scheme"
    end

    test "rejects jar:// URLs (Java archive URLs)" do
      assert {:error, msg} = HTTP.validate_endpoint_url("jar:http://example.com/app.jar!/")
      assert msg =~ "Invalid scheme"
    end

    test "rejects URLs with user info (credentials in URL)" do
      urls_with_userinfo = [
        "http://user:password@example.com/api",
        "https://admin:secret@api.example.com/v1/traces",
        "http://token@localhost:4318/metrics",
        "https://user:p@ssw0rd@example.com/logs"
      ]

      for url <- urls_with_userinfo do
        assert {:error, msg} = HTTP.validate_endpoint_url(url)
        assert msg =~ "User info in URL not allowed"
        assert msg =~ "use headers for auth"
      end
    end

    test "rejects URLs with missing host" do
      invalid_urls = [
        "http://",
        "https://",
        "http:///path/to/resource"
      ]

      for url <- invalid_urls do
        assert {:error, msg} = HTTP.validate_endpoint_url(url)
        assert msg =~ "Missing or empty host"
      end
    end

    test "accepts nil and empty string (allowing unset endpoints)" do
      assert {:ok, nil} = HTTP.validate_endpoint_url(nil)
      assert {:ok, nil} = HTTP.validate_endpoint_url("")
    end

    test "comprehensive SSRF payload rejection" do
      ssrf_payloads = [
        # Local file access
        "file:///etc/passwd",
        "file:///C:/Windows/win.ini",

        # Internal network scanning
        "http://169.254.169.254/latest/meta-data/",  # AWS metadata
        "http://metadata.google.internal/computeMetadata/v1/",  # GCP metadata

        # Protocol smuggling
        "gopher://127.0.0.1:6379/_GET%20key",
        "dict://localhost:11211/stats",

        # Data URI
        "data:text/html,<script>alert('xss')</script>",

        # LDAP injection
        "ldap://localhost:389/o=base?objectClass?one",

        # FTP bounce
        "ftp://user:pass@localhost/sensitive_file.txt",

        # Custom protocols
        "jar:http://evil.com/payload.jar!/",
        "netdoc:///etc/passwd",
        "mailto:user@example.com?body=phishing"
      ]

      for payload <- ssrf_payloads do
        result = HTTP.validate_endpoint_url(payload)
        assert match?({:error, _}, result), "Expected #{payload} to be rejected"
      end
    end

    test "allows URLs with query parameters" do
      url = "http://example.com/api?key=value&foo=bar"
      assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
    end

    test "allows URLs with fragments" do
      url = "https://example.com/api#section"
      assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
    end

    test "allows URLs with custom ports" do
      urls = [
        "http://localhost:9090/metrics",
        "https://example.com:8443/api",
        "http://192.168.1.1:3000/traces"
      ]

      for url <- urls do
        assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
      end
    end

    test "allows IPv6 addresses" do
      urls = [
        "http://[::1]:4318/v1/traces",
        "http://[2001:db8::1]:8080/metrics",
        "https://[fe80::1]:443/logs"
      ]

      for url <- urls do
        assert {:ok, ^url} = HTTP.validate_endpoint_url(url)
      end
    end
  end
end
