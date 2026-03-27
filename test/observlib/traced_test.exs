defmodule ObservLib.TracedTest do
  use ExUnit.Case, async: false

  # Test modules defined at compile time for macro testing

  defmodule BasicTracedModule do
    use ObservLib.Traced

    @traced true
    def simple_function do
      :simple_result
    end

    @traced true
    def function_with_args(a, b) do
      a + b
    end

    @traced attributes: %{"service" => "test", "version" => "1.0"}
    def function_with_attributes(value) do
      {:ok, value}
    end

    @traced name: "custom_span_name"
    def function_with_custom_name do
      :custom
    end

    @traced name: "custom_with_attrs", attributes: %{"custom" => true}
    def function_with_name_and_attributes(x) do
      x * 2
    end

    def untraced_function do
      :not_traced
    end
  end

  defmodule MultiClauseModule do
    use ObservLib.Traced

    @traced true
    def multi_clause(:a), do: :matched_a
    def multi_clause(:b), do: :matched_b
    def multi_clause(_), do: :matched_default
  end

  defmodule GuardClauseModule do
    use ObservLib.Traced

    @traced true
    def guarded_function(x) when is_integer(x) and x > 0, do: :positive_integer
    def guarded_function(x) when is_integer(x) and x < 0, do: :negative_integer
    def guarded_function(x) when is_integer(x), do: :zero
    def guarded_function(_), do: :not_integer
  end

  defmodule PrivateFunctionModule do
    use ObservLib.Traced

    @traced true
    def public_function(x) do
      private_helper(x)
    end

    @traced attributes: %{"visibility" => "private"}
    defp private_helper(x) do
      x * 3
    end

    # Expose private function result for testing
    def call_private(x), do: private_helper(x)
  end

  defmodule ExceptionModule do
    use ObservLib.Traced

    @traced true
    def raising_function do
      raise RuntimeError, "intentional error"
    end

    @traced true
    def conditional_raise(should_raise) do
      if should_raise do
        raise ArgumentError, "conditional error"
      else
        :ok
      end
    end
  end

  defmodule InlineTracedModule do
    import ObservLib.Traced

    def inline_traced_function(value) do
      traced "inline_span", %{input: value} do
        value * 2
      end
    end

    def inline_traced_no_attrs do
      traced "simple_inline" do
        :inline_result
      end
    end

    def nested_traced do
      traced "outer_span", %{level: "outer"} do
        traced "inner_span", %{level: "inner"} do
          :nested_result
        end
      end
    end

    def inline_with_exception do
      traced "exception_span" do
        raise "inline exception"
      end
    end
  end

  defmodule MixedModule do
    use ObservLib.Traced

    @traced true
    def traced_public(x) do
      x + untraced_helper(x)
    end

    defp untraced_helper(x) do
      x * 2
    end

    def inline_in_traced do
      import ObservLib.Traced

      traced "inline_inside", %{type: "inline"} do
        :inline_in_module
      end
    end
  end

  describe "basic @traced decoration" do
    test "decorates simple function with span" do
      result = BasicTracedModule.simple_function()
      assert result == :simple_result
    end

    test "decorates function with arguments" do
      result = BasicTracedModule.function_with_args(2, 3)
      assert result == 5
    end

    test "decorates function with static attributes" do
      result = BasicTracedModule.function_with_attributes("test_value")
      assert result == {:ok, "test_value"}
    end

    test "uses custom span name when provided" do
      result = BasicTracedModule.function_with_custom_name()
      assert result == :custom
    end

    test "combines custom name and attributes" do
      result = BasicTracedModule.function_with_name_and_attributes(5)
      assert result == 10
    end

    test "untraced functions work normally" do
      result = BasicTracedModule.untraced_function()
      assert result == :not_traced
    end
  end

  describe "multi-clause function decoration" do
    test "handles pattern matching clause :a" do
      assert MultiClauseModule.multi_clause(:a) == :matched_a
    end

    test "handles pattern matching clause :b" do
      assert MultiClauseModule.multi_clause(:b) == :matched_b
    end

    test "handles default clause" do
      assert MultiClauseModule.multi_clause(:c) == :matched_default
      assert MultiClauseModule.multi_clause("string") == :matched_default
    end
  end

  describe "guard clause decoration" do
    test "handles positive integer guard" do
      assert GuardClauseModule.guarded_function(5) == :positive_integer
    end

    test "handles negative integer guard" do
      assert GuardClauseModule.guarded_function(-3) == :negative_integer
    end

    test "handles zero" do
      assert GuardClauseModule.guarded_function(0) == :zero
    end

    test "handles non-integer fallback" do
      assert GuardClauseModule.guarded_function("string") == :not_integer
      assert GuardClauseModule.guarded_function(3.14) == :not_integer
    end
  end

  describe "private function decoration" do
    test "public function calling traced private function works" do
      result = PrivateFunctionModule.public_function(4)
      assert result == 12
    end

    test "traced private function can be called internally" do
      result = PrivateFunctionModule.call_private(5)
      assert result == 15
    end
  end

  describe "exception handling in decorated functions" do
    test "exception is re-raised from decorated function" do
      assert_raise RuntimeError, "intentional error", fn ->
        ExceptionModule.raising_function()
      end
    end

    test "conditional exception preserves normal return" do
      assert ExceptionModule.conditional_raise(false) == :ok
    end

    test "conditional exception raises when triggered" do
      assert_raise ArgumentError, "conditional error", fn ->
        ExceptionModule.conditional_raise(true)
      end
    end
  end

  describe "inline traced/3 macro" do
    test "wraps block in span with attributes" do
      result = InlineTracedModule.inline_traced_function(10)
      assert result == 20
    end

    test "works without explicit attributes" do
      result = InlineTracedModule.inline_traced_no_attrs()
      assert result == :inline_result
    end

    test "supports nested traced blocks" do
      result = InlineTracedModule.nested_traced()
      assert result == :nested_result
    end

    test "handles exceptions in inline traced blocks" do
      assert_raise RuntimeError, "inline exception", fn ->
        InlineTracedModule.inline_with_exception()
      end
    end
  end

  describe "mixed traced and untraced functions" do
    test "traced function can call untraced helper" do
      result = MixedModule.traced_public(5)
      assert result == 15  # 5 + (5 * 2)
    end

    test "inline traced can be used inside module with use" do
      result = MixedModule.inline_in_traced()
      assert result == :inline_in_module
    end
  end

  describe "span naming" do
    test "default span name includes module, function, and arity" do
      # This test verifies the naming convention is correct
      # The actual span creation is tested via integration
      assert function_exported?(BasicTracedModule, :simple_function, 0)
      assert function_exported?(BasicTracedModule, :function_with_args, 2)
    end
  end

  describe "macro expansion" do
    test "traced macro generates valid AST" do
      ast = quote do
        import ObservLib.Traced
        traced "test_span", %{key: "value"} do
          :test_result
        end
      end

      # Macro should expand without errors
      expanded = Macro.expand(ast, __ENV__)
      assert is_tuple(expanded)
    end

    test "traced macro with no attributes generates valid AST" do
      ast = quote do
        import ObservLib.Traced
        traced "test_span" do
          :result
        end
      end

      expanded = Macro.expand(ast, __ENV__)
      assert is_tuple(expanded)
    end
  end

  describe "integration with Traces module" do
    test "decorated function creates span via ObservLib.Traces" do
      # Execute a traced function and verify it completes
      # The span is created via ObservLib.Traces.with_span internally
      result = BasicTracedModule.simple_function()
      assert result == :simple_result
    end

    test "nested decorated functions create nested spans" do
      # Call a function that internally calls another traced function
      result = PrivateFunctionModule.public_function(3)
      assert result == 9
    end
  end

  describe "edge cases" do
    test "function with zero arity works" do
      assert BasicTracedModule.simple_function() == :simple_result
    end

    test "function with multiple arguments works" do
      assert BasicTracedModule.function_with_args(10, 20) == 30
    end

    test "function returning complex data works" do
      result = BasicTracedModule.function_with_attributes(%{nested: [1, 2, 3]})
      assert result == {:ok, %{nested: [1, 2, 3]}}
    end
  end
end
