defmodule ObservLib.Security.PyroscopeUrlInjectionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :security

  # NEW-001: Pyroscope URL Parameter Injection via Label Keys
  # Severity: HIGH (re-assessed — URI.encode/1 does NOT encode &, =, ?, /, # or ,
  # because Elixir treats them as "reserved" chars that are allowed unescaped in URIs.)
  #
  # Root cause (lib/observlib/pyroscope/client.ex:443-448):
  #   labels_string = labels |> Enum.map(fn {k,v} -> "#{k}=#{v}" end) |> Enum.join(",")
  #   url = "#{endpoint}/ingest?name=#{URI.encode(labels_string)}&..."
  #
  # URI.encode/1 uses URI.char_unescaped?/1 which includes reserved chars (& = ? / # , ; !)
  # as "unescaped". This means a label key like "foo&evil=1" produces a URL with
  # &evil=1 as a separate query parameter — injection is possible.
  #
  # Recommended fix: Use URI.encode_www_form/1 per key and value individually.

  # Replicates the current (vulnerable) URL construction in Pyroscope.Client.build_ingest_url/3
  defp build_url_current(endpoint, service_name, labels) do
    labels_with_service = Map.put(labels, "__name__", "#{service_name}.cpu")

    labels_string =
      labels_with_service
      |> Enum.map_join(",", fn {k, v} -> "#{k}=#{v}" end)

    "#{endpoint}/ingest?name=#{URI.encode(labels_string)}&spyName=elixir&sampleRate=100"
  end

  # Secure alternative using per-key-value www-form encoding.
  # Each label key and value is individually percent-encoded, then the pairs are
  # joined with "," (the Pyroscope label separator). The assembled labels_string
  # is placed directly as the name= parameter value — NOT re-encoded — because
  # the individual percent-encoding has already made the chars URL-safe.
  defp build_url_secure(endpoint, service_name, labels) do
    labels_with_service = Map.put(labels, "__name__", "#{service_name}.cpu")

    labels_string =
      labels_with_service
      |> Enum.map_join(",", fn {k, v} ->
        "#{URI.encode_www_form(to_string(k))}=#{URI.encode_www_form(to_string(v))}"
      end)

    # labels_string keys/values are already percent-encoded; put it directly as name= value
    "#{endpoint}/ingest?name=#{labels_string}&spyName=elixir&sampleRate=100"
  end

  describe "NEW-001: Pyroscope URL injection — URI.encode/1 does NOT encode reserved chars" do
    # These tests DOCUMENT THE VULNERABILITY by showing that URI.encode/1
    # leaves & and other injection chars unencoded.

    test "URI.encode does NOT encode & — label key with & injects a query parameter" do
      url = build_url_current("http://localhost:4040", "myapp", %{"foo&evil" => "1"})

      # URI.encode leaves & unencoded → it appears raw in the query string
      assert String.contains?(url, "&evil="),
             "URI.encode leaves & raw, enabling query param injection; url: #{url}"

      # This confirms the vulnerability: the URL has &evil= as a separate param
      parsed = URI.parse(url)
      query_params = URI.decode_query(parsed.query)

      # evil=1 is injected as a separate query parameter
      assert Map.has_key?(query_params, "evil"),
             "Label '&evil' injected 'evil' as a separate query param; url: #{url}"
    end

    test "URI.encode does NOT encode = — label key with = injects into name param structure" do
      url = build_url_current("http://localhost:4040", "myapp", %{"k=injected_key" => "v"})

      # = is not encoded, creating name=k=injected_key... which is ambiguous
      assert String.contains?(url, "=injected_key"),
             "URI.encode leaves = raw in label key; url: #{url}"
    end

    test "URI.encode does NOT encode # — label key with # starts a URL fragment" do
      url = build_url_current("http://localhost:4040", "myapp", %{"tag#fragment" => "v"})
      parsed = URI.parse(url)

      # # terminates the query and starts a fragment
      # This means everything after # in the label is lost from the HTTP request
      assert parsed.fragment != nil,
             "URI.encode leaves # raw, causing URL to have a fragment: #{url}"
    end

    test "URI.encode does NOT encode , — comma in label value injects extra labels" do
      url = build_url_current("http://localhost:4040", "myapp", %{"role" => "user,admin=true"})

      # , is not encoded → "role=user,admin=true" → server sees extra label admin=true
      assert String.contains?(url, "user,admin=true"),
             "Comma in label value is not encoded, enabling label injection; url: #{url}"
    end
  end

  describe "NEW-001: Secure alternative — URI.encode_www_form/1 per key/value prevents injection" do
    # These tests show that applying URI.encode_www_form/1 per key and value
    # correctly encodes injection chars and prevents URL manipulation.

    test "encode_www_form encodes & in label keys as %26" do
      url = build_url_secure("http://localhost:4040", "myapp", %{"foo&evil" => "1"})

      # & should be encoded as %26
      refute String.contains?(url, "&evil"),
             "& in label key must be encoded; url: #{url}"

      assert String.contains?(url, "%26"),
             "& should appear as %26 in the URL; url: #{url}"

      # No injection: evil is not a separate query param
      parsed = URI.parse(url)
      query_params = URI.decode_query(parsed.query)

      refute Map.has_key?(query_params, "evil"),
             "'evil' must not appear as a separate query param; url: #{url}"
    end

    test "encode_www_form encodes # in label keys as %23, preventing fragment injection" do
      url = build_url_secure("http://localhost:4040", "myapp", %{"tag#section" => "v1"})
      parsed = URI.parse(url)

      assert parsed.fragment == nil,
             "Secure URL must not have a URL fragment; url: #{url}"

      assert String.contains?(url, "%23"),
             "# should be encoded as %23; url: #{url}"
    end

    test "encode_www_form encodes , in label values as %2C, preventing label injection" do
      url = build_url_secure("http://localhost:4040", "myapp", %{"role" => "user,admin=true"})

      refute String.contains?(url, "user,admin"),
             "Comma must be encoded to prevent label injection; url: #{url}"

      assert String.contains?(url, "user%2Cadmin") or String.contains?(url, "%2C"),
             "Comma should be encoded as %2C; url: #{url}"
    end

    test "encode_www_form encodes = in label keys as %3D" do
      url = build_url_secure("http://localhost:4040", "myapp", %{"foo=bar" => "v"})

      assert String.contains?(url, "%3D"),
             "= in label key should be encoded as %3D; url: #{url}"
    end

    test "null byte in label key is encoded, not passed raw" do
      url = build_url_secure("http://localhost:4040", "myapp", %{"key\x00null" => "v"})

      refute String.contains?(url, <<0>>),
             "Null byte must not appear raw in URL; url: #{inspect(url)}"
    end

    test "URL structure remains valid with benign labels using secure encoding" do
      url =
        build_url_secure("http://localhost:4040", "myapp", %{
          "env" => "production",
          "region" => "us-east-1"
        })

      parsed = URI.parse(url)

      assert parsed.scheme == "http"
      assert parsed.host == "localhost"
      assert parsed.port == 4040
      assert parsed.path == "/ingest"
      assert String.starts_with?(parsed.query, "name=")
      assert String.contains?(parsed.query, "spyName=elixir")
    end

    property "secure encoding: arbitrary label keys never produce unencoded & or # in query" do
      check all(
              label_key <- StreamData.string(:printable, length: 1..32),
              label_value <- StreamData.string(:printable, length: 1..16)
            ) do
        url = build_url_secure("http://localhost:4040", "app", %{label_key => label_value})
        parsed = URI.parse(url)

        # No raw # should appear in the query portion (would start a fragment)
        assert parsed.fragment == nil,
               "Secure URL must not have a fragment for key=#{inspect(label_key)}"

        # The query should contain the name= parameter
        assert parsed.query != nil and String.contains?(parsed.query, "name="),
               "Secure URL must have a name= parameter; url=#{url}"
      end
    end
  end
end
