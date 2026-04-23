defmodule ObservLib.Attributes do
  @moduledoc """
  Attribute validation and sanitization for traces, metrics, and logs.

  Enforces configurable limits:
  - max_attribute_value_size (default: 4KB)
  - max_attribute_count (default: 128)
  - redacted_attribute_keys (default: sensitive key patterns)

  Prevents resource exhaustion attacks by truncating oversized values,
  limiting the number of attributes per operation, and redacting sensitive
  attribute keys before export.
  """

  require Logger

  @doc """
  Validates and sanitizes attributes map.

  Returns {:ok, sanitized_attrs} with truncated values, limited count,
  and redacted sensitive keys.

  ## Examples

      iex> ObservLib.Attributes.validate(%{"key" => "value"})
      {:ok, %{"key" => "value"}}

      iex> large_value = String.duplicate("x", 10_000)
      iex> {:ok, attrs} = ObservLib.Attributes.validate(%{"data" => large_value})
      iex> String.ends_with?(attrs["data"], "...[TRUNC]")
      true

      iex> ObservLib.Attributes.validate(%{"password" => "secret123"})
      {:ok, %{"password" => "[REDACTED]"}}

  """
  @spec validate(map()) :: {:ok, map()}
  def validate(attributes) when is_map(attributes) do
    max_size = ObservLib.Config.get(:max_attribute_value_size, 4096)
    max_count = ObservLib.Config.get(:max_attribute_count, 128)

    cond do
      map_size(attributes) > max_count ->
        # Truncate to first max_count attributes
        truncated = attributes |> Enum.take(max_count) |> Map.new()

        Logger.warning("Attribute count exceeded",
          limit: max_count,
          count: map_size(attributes)
        )

        {:ok, truncated |> truncate_values(max_size) |> redact_sensitive()}

      true ->
        {:ok, attributes |> truncate_values(max_size) |> redact_sensitive()}
    end
  end

  def validate(_attributes), do: {:ok, %{}}

  @spec redact_sensitive(map()) :: map()
  defp redact_sensitive(attributes) when is_map(attributes) do
    # nil means "use the default list" (config.exs sets the key to nil by default)
    redacted_keys =
      ObservLib.Config.get(:redacted_attribute_keys, default_redacted_keys()) ||
        default_redacted_keys()

    redaction_pattern = ObservLib.Config.get(:redaction_pattern, "[REDACTED]")

    Map.new(attributes, fn {k, v} ->
      if should_redact?(k, redacted_keys) do
        {k, redaction_pattern}
      else
        {k, v}
      end
    end)
  end

  @spec should_redact?(String.t(), list(String.t())) :: boolean()
  defp should_redact?(key, redacted_keys) when is_binary(key) do
    key_lower = String.downcase(key)

    Enum.any?(redacted_keys, fn pattern ->
      pattern_lower = String.downcase(pattern)
      String.contains?(key_lower, pattern_lower)
    end)
  end

  defp should_redact?(_key, _redacted_keys), do: false

  @spec default_redacted_keys() :: list(String.t())
  defp default_redacted_keys do
    [
      "password",
      "passwd",
      "secret",
      "token",
      "authorization",
      "auth",
      "api_key",
      "apikey",
      "access_key",
      "private_key",
      "credit_card",
      "creditcard",
      "card_number",
      "cvv",
      "ssn",
      "social_security",
      "bearer",
      "session"
    ]
  end

  @spec truncate_values(map(), non_neg_integer()) :: map()
  defp truncate_values(attributes, max_size) do
    Map.new(attributes, fn {k, v} ->
      {k, truncate_value(v, max_size)}
    end)
  end

  @spec truncate_value(any(), non_neg_integer()) :: any()
  defp truncate_value(value, max_size) when is_binary(value) do
    if byte_size(value) > max_size do
      suffix = "...[TRUNC]"
      truncate_length = max_size - byte_size(suffix)

      Logger.warning("Attribute value truncated",
        original_size: byte_size(value),
        truncated_size: max_size
      )

      <<truncated::binary-size(truncate_length), _::binary>> = value
      truncated <> suffix
    else
      value
    end
  end

  defp truncate_value(value, _max_size), do: value
end
