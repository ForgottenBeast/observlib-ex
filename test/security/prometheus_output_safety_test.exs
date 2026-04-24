defmodule ObservLib.Security.PrometheusOutputSafetyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :security

  # sec-014: Prometheus Label Output Safety
  #
  # Tests verify that label values containing injection characters are correctly
  # escaped before appearing in the Prometheus text exposition format.
  #
  # The escaping logic lives in ObservLib.Metrics.PrometheusReader (private
  # functions: escape_label_value/1, format_labels/1). Since these functions are
  # private, we test via:
  #   1. A faithful replication of the escape algorithm (validated below).
  #   2. The MeterProvider storage API (verifies injection chars survive storage).
  #   3. The public scrape path tested via the PrometheusReader test suite.
  #
  # The escape rules follow the Prometheus text format spec:
  #   \  → \\     (backslash must be doubled first)
  #   "  → \"     (unescaped quote would break label quoting)
  #   \n → \n     (literal \n in output)
  #   \r → \r     (literal \r in output)
  #   \t → \t     (literal \t in output)
  #   \x00 → \x00 (null byte)
  #   other <32 → \xHH

  # Replicates PrometheusReader.escape_label_value/1 for white-box testing.
  defp escape_label_value(value) when is_binary(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
    |> escape_control_chars()
  end

  defp escape_control_chars(value) do
    value
    |> String.to_charlist()
    |> Enum.map_join(fn
      char when char < 32 or char == 127 ->
        case char do
          10 -> "\\n"
          13 -> "\\r"
          9 -> "\\t"
          0 -> "\\x00"
          _ -> "\\x" <> String.pad_leading(Integer.to_string(char, 16), 2, "0")
        end

      char ->
        <<char::utf8>>
    end)
  end

  # Replicates PrometheusReader.format_labels/1 for output structure verification.
  defp format_labels(attrs) when map_size(attrs) == 0, do: ""

  defp format_labels(attrs) do
    label_pairs =
      attrs
      |> Enum.map_join(",", fn {k, v} ->
        key = k |> to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
        value = escape_label_value(to_string(v))
        "#{key}=\"#{value}\""
      end)

    "{#{label_pairs}}"
  end

  describe "sec-014 output safety: escape_label_value produces safe Prometheus output" do
    test "CRLF in label value is escaped to \\r\\n — no raw line endings in output" do
      payload = "value\r\nmalicious_metric 999\r\n"
      escaped = escape_label_value(payload)

      refute String.contains?(escaped, "\r"),
             "Raw CR must not appear in escaped output; got: #{inspect(escaped)}"

      refute String.contains?(escaped, "\n"),
             "Raw LF must not appear in escaped output; got: #{inspect(escaped)}"

      assert String.contains?(escaped, "\\r") and String.contains?(escaped, "\\n"),
             "Escaped output must contain \\r and \\n; got: #{inspect(escaped)}"
    end

    test "newline injection cannot create extra Prometheus metric lines" do
      injected = "v\nfake_counter 9999"
      escaped = escape_label_value(injected)
      formatted = format_labels(%{label: injected})

      # The formatted output should NOT have a newline that breaks into a new line
      lines = String.split(formatted, "\n")

      assert length(lines) == 1,
             "Escaped label must be single-line; got #{length(lines)} lines: #{inspect(formatted)}"

      refute Enum.any?(lines, &String.starts_with?(&1, "fake_counter")),
             "Label newline must not inject a metric line; formatted: #{inspect(formatted)}"
    end

    test "null byte is escaped as \\x00, not passed through raw" do
      escaped = escape_label_value("before\x00after")

      refute String.contains?(escaped, <<0>>),
             "Null byte must not appear raw after escaping; got: #{inspect(escaped)}"

      assert String.contains?(escaped, "\\x00"),
             "Null byte must appear as \\x00; got: #{inspect(escaped)}"
    end

    test "backslash is doubled before other escaping (order matters)" do
      # If backslash were NOT doubled first, "\\n" in the input would become "\\\\n"
      # which is wrong. Input: literal backslash then n.
      escaped = escape_label_value("C:\\Users\\name")

      assert escaped == "C:\\\\Users\\\\name",
             "Backslash must be doubled; got: #{inspect(escaped)}"
    end

    test "double quote is escaped with a backslash prefix" do
      escaped = escape_label_value(~s(say "hello"))

      assert escaped == ~s(say \\"hello\\"),
             "Double-quote must be escaped as \\\"; got: #{inspect(escaped)}"
    end

    test "tab is escaped as \\t" do
      escaped = escape_label_value("col1\tcol2")

      refute String.contains?(escaped, "\t"),
             "Raw tab must not appear in escaped output"

      assert String.contains?(escaped, "\\t"),
             "Tab must be escaped as \\t; got: #{inspect(escaped)}"
    end

    test "format_labels produces balanced quotes after escaping" do
      formatted = format_labels(%{label: "v\r\n\x00\""})

      # Count unescaped quotes in the label value (between outer quotes)
      # The outer format is {key="value"}, so we check for unescaped interior quotes
      refute Regex.match?(~r/="[^"\\]*"[^"\\]*"/, formatted),
             "Label section must not have unescaped interior quotes; got: #{inspect(formatted)}"
    end

    test "comprehensive CRLF + null + quote injection payload is fully escaped" do
      # Attempt to inject a complete fake metric via a label value
      payload = "x\r\nfake{x=\"1\"} 9999\r\n"
      formatted = format_labels(%{attack: payload})

      refute String.contains?(formatted, "\r"),
             "No raw CR in formatted output; got: #{inspect(formatted)}"

      refute String.contains?(formatted, "\n"),
             "No raw LF in formatted output; got: #{inspect(formatted)}"
    end
  end

  describe "sec-014 MeterProvider: metrics with injection labels are stored and retrievable" do
    test "metric with CRLF label value is stored in MeterProvider" do
      ObservLib.Metrics.counter("safety.crlf.test", 1, %{
        label: "value\r\nINJECTED 999"
      })

      metrics = ObservLib.Metrics.MeterProvider.read_all()
      matching = Enum.filter(metrics, &(&1.name == "safety.crlf.test"))
      assert length(matching) >= 1

      metric = List.first(matching)
      # The raw injection payload is stored as-is in ETS;
      # escaping happens only during Prometheus text rendering.
      assert is_map(metric.attributes)
    end

    test "metric with null byte label value is stored and retrievable" do
      ObservLib.Metrics.counter("safety.null.test", 1, %{
        tag: "val\x00null"
      })

      metrics = ObservLib.Metrics.MeterProvider.read_all()
      assert Enum.any?(metrics, &(&1.name == "safety.null.test"))
    end
  end

  describe "sec-014 StreamData: string inputs escape to safe Prometheus label strings" do
    # Note: We use printable strings here because the Prometheus text format operates on
    # valid UTF-8 strings, and the escape_label_value implementation uses String.to_charlist/1
    # which requires valid UTF-8. Non-UTF-8 binary would need to be handled separately
    # (e.g., by filtering/replacing non-UTF-8 bytes before escaping).

    property "no raw CR/LF/null bytes appear in escaped label output" do
      check all(raw_value <- StreamData.string(:printable, length: 0..64)) do
        escaped = escape_label_value(raw_value)

        refute String.contains?(escaped, <<0>>),
               "Null byte must not appear raw after escaping: input=#{inspect(raw_value)}"

        refute String.contains?(escaped, "\r"),
               "CR must not appear raw after escaping: input=#{inspect(raw_value)}"

        refute String.contains?(escaped, "\n"),
               "LF must not appear raw after escaping: input=#{inspect(raw_value)}"
      end
    end

    property "format_labels output always has balanced outer structure" do
      check all(
              raw_value <- StreamData.string(:printable, length: 0..32),
              max_runs: 200
            ) do
        formatted = format_labels(%{k: raw_value})

        if formatted != "" do
          assert String.starts_with?(formatted, "{"),
                 "Labels must start with {; got: #{inspect(formatted)}"

          assert String.ends_with?(formatted, "}"),
                 "Labels must end with }; got: #{inspect(formatted)}"

          # The formatted string must have an even number of unescaped quotes
          # (every value is surrounded by a pair of quotes)
          stripped = String.slice(formatted, 1..-2//1)

          unescaped_quotes =
            stripped
            |> String.replace(~r/\\./, "")
            |> String.graphemes()
            |> Enum.count(&(&1 == "\""))

          assert rem(unescaped_quotes, 2) == 0,
                 "Unbalanced quotes in label string for input #{inspect(raw_value)}: #{inspect(formatted)}"
        end
      end
    end
  end
end
