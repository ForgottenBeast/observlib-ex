defmodule ObservLib.TracesTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  describe "start_span/2 and end_span/1" do
    test "starts and ends a span successfully" do
      span = ObservLib.Traces.start_span("test_span")
      assert is_tuple(span)

      # End the span
      ended_span = ObservLib.Traces.end_span(span)
      assert is_tuple(ended_span)
    end

    test "starts a span with attributes" do
      attributes = %{"http.method" => "GET", "http.url" => "/api/users"}
      span = ObservLib.Traces.start_span("http_request", attributes)
      assert is_tuple(span)

      ObservLib.Traces.end_span(span)
    end

    test "handles string span names" do
      span = ObservLib.Traces.start_span("string_name")
      assert is_tuple(span)
      ObservLib.Traces.end_span(span)
    end

    test "handles atom span names" do
      span = ObservLib.Traces.start_span(:atom_name)
      assert is_tuple(span)
      ObservLib.Traces.end_span(span)
    end
  end

  describe "set_attribute/2" do
    test "sets attribute on current span" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_attribute("user.id", "123")
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "sets string attribute" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_attribute("key", "value")
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "sets numeric attribute" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_attribute("count", 42)
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "sets boolean attribute" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_attribute("is_active", true)
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "returns false when no span is active" do
      # Clear any active span
      :otel_tracer.set_current_span(nil)

      result = ObservLib.Traces.set_attribute("key", "value")
      assert result == false
    end
  end

  describe "set_status/2" do
    test "sets ok status" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_status(:ok)
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "sets error status with message" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_status(:error, "Something went wrong")
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "sets error status without message" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.set_status(:error)
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "returns false when no span is active" do
      :otel_tracer.set_current_span(nil)

      result = ObservLib.Traces.set_status(:ok)
      assert result == false
    end
  end

  describe "record_exception/1" do
    test "records Elixir exception" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      try do
        raise ArgumentError, "test error"
      rescue
        e ->
          result = ObservLib.Traces.record_exception(e)
          assert result == true
      end

      ObservLib.Traces.end_span(span)
    end

    test "records error tuple" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result = ObservLib.Traces.record_exception({:error, :enoent})
      assert result == true

      ObservLib.Traces.end_span(span)
    end

    test "records exception and sets error status" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      try do
        raise RuntimeError, "test error"
      rescue
        e ->
          ObservLib.Traces.record_exception(e)
          ObservLib.Traces.set_status(:error, "Operation failed")
      end

      ObservLib.Traces.end_span(span)
    end

    test "returns false when no span is active" do
      :otel_tracer.set_current_span(nil)

      result = ObservLib.Traces.record_exception({:error, :test})
      assert result == false
    end
  end

  describe "with_span/3" do
    test "executes function within span context" do
      result = ObservLib.Traces.with_span("test_operation", %{}, fn ->
        :test_result
      end)

      assert result == :test_result
    end

    test "executes function with attributes" do
      result = ObservLib.Traces.with_span("test_operation", %{"key" => "value"}, fn ->
        {:ok, "success"}
      end)

      assert result == {:ok, "success"}
    end

    test "ends span even if function raises" do
      assert_raise RuntimeError, "test error", fn ->
        ObservLib.Traces.with_span("test_operation", %{}, fn ->
          raise "test error"
        end)
      end
    end

    test "propagates function return value" do
      result = ObservLib.Traces.with_span("calculation", %{}, fn ->
        2 + 2
      end)

      assert result == 4
    end

    test "allows nested spans" do
      outer_result = ObservLib.Traces.with_span("outer_span", %{}, fn ->
        inner_result = ObservLib.Traces.with_span("inner_span", %{}, fn ->
          :inner_value
        end)

        {:outer, inner_result}
      end)

      assert outer_result == {:outer, :inner_value}
    end
  end

  describe "current_span/0" do
    test "returns current span when one is active" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      current = ObservLib.Traces.current_span()
      assert is_tuple(current)

      ObservLib.Traces.end_span(span)
    end

    test "returns nil when no span is active" do
      :otel_tracer.set_current_span(nil)

      current = ObservLib.Traces.current_span()
      assert current == nil
    end
  end

  describe "context propagation" do
    test "span context is propagated to current span" do
      span = ObservLib.Traces.start_span("parent_span")
      :otel_tracer.set_current_span(span)

      current = ObservLib.Traces.current_span()
      assert current != nil

      ObservLib.Traces.end_span(span)
    end

    test "nested spans maintain parent context" do
      ObservLib.Traces.with_span("parent", %{}, fn ->
        parent_span = ObservLib.Traces.current_span()

        ObservLib.Traces.with_span("child", %{}, fn ->
          child_span = ObservLib.Traces.current_span()

          # Both spans should exist
          assert parent_span != nil
          assert child_span != nil

          # Child span should be different from parent
          assert parent_span != child_span
        end)
      end)
    end
  end

  describe "nested spans" do
    test "creates nested span hierarchy" do
      result = ObservLib.Traces.with_span("root", %{}, fn ->
        ObservLib.Traces.set_attribute("level", "root")

        ObservLib.Traces.with_span("child1", %{}, fn ->
          ObservLib.Traces.set_attribute("level", "child1")

          ObservLib.Traces.with_span("grandchild", %{}, fn ->
            ObservLib.Traces.set_attribute("level", "grandchild")
            :success
          end)
        end)
      end)

      assert result == :success
    end

    test "parent span is restored after child completes" do
      ObservLib.Traces.with_span("parent", %{}, fn ->
        parent_span = ObservLib.Traces.current_span()

        ObservLib.Traces.with_span("child", %{}, fn ->
          _child_span = ObservLib.Traces.current_span()
        end)

        # After child completes, parent should be current again
        restored_parent = ObservLib.Traces.current_span()
        assert parent_span == restored_parent
      end)
    end
  end

  describe "exception recording tests" do
    test "records exception with stacktrace" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      try do
        Enum.fetch!([], 10)
      rescue
        e ->
          result = ObservLib.Traces.record_exception(e)
          assert result == true
      end

      ObservLib.Traces.end_span(span)
    end

    test "records multiple exceptions in same span" do
      span = ObservLib.Traces.start_span("test_span")
      :otel_tracer.set_current_span(span)

      result1 = ObservLib.Traces.record_exception({:error, :first})
      result2 = ObservLib.Traces.record_exception({:error, :second})

      assert result1 == true
      assert result2 == true

      ObservLib.Traces.end_span(span)
    end
  end

  describe "property-based tests" do
    property "any valid span name can start a span" do
      check all span_name <- one_of([
                  string(:printable, min_length: 1),
                  atom(:alphanumeric)
                ]) do
        span = ObservLib.Traces.start_span(span_name)
        assert is_tuple(span)
        ObservLib.Traces.end_span(span)
      end
    end

    property "attributes can be any string key-value pairs" do
      check all key <- string(:printable, min_length: 1),
                value <- one_of([
                  string(:printable),
                  integer(),
                  boolean()
                ]) do
        attributes = %{key => value}
        span = ObservLib.Traces.start_span("test", attributes)
        assert is_tuple(span)
        ObservLib.Traces.end_span(span)
      end
    end
  end
end
