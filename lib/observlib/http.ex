defmodule ObservLib.HTTP do
  @moduledoc """
  HTTP client module with TLS configuration for ObservLib.

  Wraps HTTP requests with security features:
  - TLS verification enabled by default
  - Support for custom CA certificates
  - Configurable TLS versions and ciphers
  - Warnings for plaintext HTTP to remote hosts

  ## Configuration

      config :observlib,
        tls_verify: true,                         # Enable TLS certificate verification
        tls_ca_cert_file: nil,                    # Path to custom CA certificate file
        tls_versions: [:"tlsv1.3", :"tlsv1.2"],  # Allowed TLS versions
        tls_ciphers: :default                     # Cipher suite configuration

  ## Examples

      # POST with automatic TLS configuration
      ObservLib.HTTP.post("https://api.example.com/data", json: %{key: "value"})

      # POST to localhost (plaintext allowed)
      ObservLib.HTTP.post("http://localhost:4318/v1/metrics", json: metrics)

  """

  require Logger

  @doc """
  Redacts sensitive headers from error context before logging.

  Removes Authorization, X-API-Key, X-Auth-Token, and similar headers
  to prevent credential leakage in error logs. Handles both map and
  other types safely.

  ## Parameters

    - `error_context` - Map or other value that may contain sensitive headers

  ## Returns

    - `map` - Map with sensitive headers redacted to "[REDACTED]"
    - `other` - Original value if not a map

  ## Examples

      iex> ObservLib.HTTP.redact_sensitive_headers(%{"Authorization" => "Bearer xyz123"})
      %{"Authorization" => "[REDACTED]"}

      iex> ObservLib.HTTP.redact_sensitive_headers("not a map")
      "not a map"

  """
  @spec redact_sensitive_headers(term()) :: term()
  def redact_sensitive_headers(error_context) when is_map(error_context) do
    sensitive_patterns = [
      "authorization",
      "x-api-key",
      "x-auth-token",
      "api-key",
      "bearer",
      "token"
    ]

    Map.new(error_context, fn {key, value} ->
      key_lower = String.downcase(to_string(key))

      should_redact = Enum.any?(sensitive_patterns, fn pattern ->
        String.contains?(key_lower, pattern)
      end)

      if should_redact do
        {key, "[REDACTED]"}
      else
        {key, value}
      end
    end)
  end

  def redact_sensitive_headers(other), do: other

  @doc """
  Sends an HTTP POST request with TLS configuration.

  ## Parameters

    - `url` - The URL to POST to
    - `opts` - Options passed to Req.post (headers, json, body, etc.)
    - `http_opts` - Additional HTTP client options (optional)

  ## Returns

    - `{:ok, response}` - Successful response
    - `{:error, reason}` - Request failed

  ## Security Features

    - HTTPS connections use TLS verification by default
    - HTTP to localhost/127.0.0.1 is allowed
    - HTTP to remote hosts produces a warning
    - Custom CA certificates can be configured
    - TLS version and cipher configuration

  """
  @spec post(String.t(), keyword(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def post(url, opts \\ [], http_opts \\ []) do
    # Parse URL to check scheme and host
    uri = URI.parse(url)

    # Warn if using plaintext HTTP to remote host
    check_plaintext_security(uri)

    # Merge TLS options if using HTTPS
    final_opts = maybe_add_tls_config(uri, opts, http_opts)

    # Make the request
    Req.post(url, final_opts)
  end

  # Private functions

  defp check_plaintext_security(%URI{scheme: "http", host: host}) do
    if not is_localhost?(host) do
      Logger.warning(
        "Plaintext HTTP connection to remote host: #{host}. " <>
          "Consider using HTTPS for secure communication."
      )
    end
  end

  defp check_plaintext_security(_uri), do: :ok

  defp is_localhost?(nil), do: false
  defp is_localhost?("localhost"), do: true
  defp is_localhost?("127.0.0.1"), do: true
  defp is_localhost?("::1"), do: true

  defp is_localhost?(host) do
    # Check for localhost variants and loopback addresses
    host
    |> String.downcase()
    |> String.starts_with?(["localhost", "127.", "::1"])
  end

  defp maybe_add_tls_config(%URI{scheme: "https"}, opts, http_opts) do
    # Get TLS configuration from application environment
    tls_verify = get_config(:tls_verify, true)
    ca_cert_file = get_config(:tls_ca_cert_file, nil)
    tls_versions = get_config(:tls_versions, [:"tlsv1.3", :"tlsv1.2"])
    tls_ciphers = get_config(:tls_ciphers, :default)

    # Build SSL options
    ssl_opts = build_ssl_options(tls_verify, ca_cert_file, tls_versions, tls_ciphers)

    # Merge with provided options
    connect_opts = Keyword.get(http_opts, :connect_options, [])
    updated_connect_opts = Keyword.merge(connect_opts, transport_opts: ssl_opts)

    # Add connect_options to opts
    Keyword.merge(opts, connect_options: updated_connect_opts)
  end

  defp maybe_add_tls_config(_uri, opts, _http_opts) do
    # Not HTTPS, return options unchanged
    opts
  end

  defp build_ssl_options(verify, ca_cert_file, tls_versions, tls_ciphers) do
    base_opts = [
      verify: if(verify, do: :verify_peer, else: :verify_none),
      versions: tls_versions
    ]

    # Add CA certificate file if provided
    opts_with_ca =
      if verify and not is_nil(ca_cert_file) do
        Keyword.put(base_opts, :cacertfile, ca_cert_file)
      else
        # Use system CA store when verifying
        if verify do
          Keyword.merge(base_opts, cacerts: :public_key.cacerts_get())
        else
          base_opts
        end
      end

    # Add cipher configuration
    case tls_ciphers do
      :default ->
        opts_with_ca

      ciphers when is_list(ciphers) ->
        Keyword.put(opts_with_ca, :ciphers, ciphers)

      _ ->
        opts_with_ca
    end
  end

  defp get_config(key, default) do
    case Application.get_env(:observlib, key, default) do
      nil -> default
      value -> value
    end
  end
end
