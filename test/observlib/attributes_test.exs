defmodule ObservLib.AttributesTest do
  use ExUnit.Case, async: true

  alias ObservLib.Attributes

  describe "validate/1" do
    test "passes through small attributes unchanged" do
      attrs = %{"key" => "value", "number" => 42}
      assert {:ok, ^attrs} = Attributes.validate(attrs)
    end

    test "truncates oversized binary values" do
      # Create a 10MB binary
      large_value = String.duplicate("x", 10_000_000)
      attrs = %{"huge_data" => large_value}

      {:ok, result} = Attributes.validate(attrs)

      # Value should be truncated
      assert String.ends_with?(result["huge_data"], "...[TRUNC]")
      # Should be approximately 4KB (default max_attribute_value_size)
      assert byte_size(result["huge_data"]) <= 4096
    end

    test "limits attribute count" do
      # Create 200 attributes (exceeds default limit of 128)
      attrs = Map.new(1..200, fn i -> {"key_#{i}", "value_#{i}"} end)

      {:ok, result} = Attributes.validate(attrs)

      # Should be limited to 128 attributes
      assert map_size(result) <= 128
    end

    test "preserves non-binary values" do
      attrs = %{"string" => "text", "number" => 42, "bool" => true, "list" => [1, 2, 3]}
      {:ok, result} = Attributes.validate(attrs)

      assert result["number"] == 42
      assert result["bool"] == true
      assert result["list"] == [1, 2, 3]
    end

    test "handles empty map" do
      assert {:ok, %{}} = Attributes.validate(%{})
    end

    test "handles non-map input" do
      assert {:ok, %{}} = Attributes.validate(nil)
      assert {:ok, %{}} = Attributes.validate("not a map")
    end
  end
end
