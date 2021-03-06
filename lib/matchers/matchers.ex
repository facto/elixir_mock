defmodule ElixirMock.Matchers do
  @moduledoc """
  Contains utility functions that allow predicate-based matching against arguments passed to mock function calls.

  The `ElixirMock.assert_called/1` and `ElixirMock.refute_called/1` macros can take matchers in place of literal arguments
  in function call verifications. A matcher is any tuple of the form `{:matches, &matcher_fn/1}` where `matcher_fn` is a
  function of arity 1 that returns a boolean given a value. That value is an argument passed to a call to the mock
  function in the same position as the matcher as declared in the call verification statement.

  ## Example
  ```
  defmodule MyTest do
    use ExUnit.Case
    require ElixirMock
    import ElixirMock

    defmodule MyModule do
      def add(a, b), do: a + b
    end

    test "add was called with an even number as the first argument" do
      an_even_number = fn(number) -> rem(number, 2) == 0 end
      mock = mock_of MyModule

      mock.add(4, 3)

      assert_called mock.add({:matches, an_even_number}, 3) # passes
      assert_called mock.add(4, {:matches, an_even_number}) # fails!
    end
  end
  ```
  The `ElixirMock.Matchers` module contains functions for common matching use cases like matching any argument,
  matching only number arguments, e.t.c. See this module's [functions list](#summary) for a list of in-built matchers.

  ## Deep matching with maps

  When a function under test is expecting map arguments, matchers can be used in the match expression for some or all
  of the map's keys. When a value of a key in an call verification statement is found to be a matcher expression, the
  matcher expression is evaluated with the corresponding value in the actual map argument. If all present matchers in the
  expected map evaluate to `true` for the corresponding values in the actual map and the values of all the other keys
  in the expected map match the values of the same keys in the actual map, the call verification statement passes.

  ```
  defmodule MyTest do
    use ExUnit.Case
    require ElixirMock
    import ElixirMock
    alias ElixirMock.Matchers

    defmodule MyModule do
      def echo(what_to_say), do: IO.puts(inspect(what_to_say))
    end

    test "echo/1 should have been called with the correct map" do
      mock = mock_of MyModule
      mock.echo %{a: 1, b: :something}
      assert_called mock.echo(%{a: Matchers.any(:int), b: Matchers.any(:atom)}) # passes
    end
  end
  ```

  __Also, note that:__
  - All the [matchers](#summary) availabe in this module can be used within maps in this fashion.
  - Matching on map values with matchers can be done with nested maps of arbitrary depth.
  """

  @doc """
  A matcher that matches any argument.

  Use it when you don't care about some or all arguments in a function call assertion. Also, since `ElixirMock.assert_called/1`
  and `ElixirMock.refute_called/1` will not match function calls with different number of arguments from what the assertion
  specifies, the `any/0` matcher is necessary to be able do assertions like the one in the example below

  Example:
  ```
  defmodule MyTest do
    use ExUnit.Case
    require ElixirMock
    import ElixirMock
    alias ElixirMock.Matchers

    defmodule MyModule do
      def echo(arg), do: IO.puts(arg)
    end

    test "echo was called with any argument" do
      mock = mock_of MyModule
      mock.echo("hello")

      # If just want to verify that '&echo/1' was called but I don't care about the arguments:
      assert_called mock.echo(Matchers.any) # passes

      # But this will not pass:
      assert_called mock.echo # fails!
    end
  end
  ```
  """
  def any, do: {:matches, ElixirMock.Matchers.InBuilt.any(:_)}

  @doc """
  A matcher that matches an argument only if it is of a specified type.

  Supported types are `:atom`, `:binary`, `:boolean`, `:float`, `:function`, `:integer`, `:list`, `:map`, `:number`,
  `:pid`, `:tuple`, any struct (e.g., `%Person{}`), and `:_` (equivalent to using `any/0`). An `ArgumentError` is thrown
  if an argument not in this list is passed to the function.

  Example:
  ```
  defmodule MyTest do
    use ExUnit.Case
    require ElixirMock
    import ElixirMock
    alias ElixirMock.Matchers

    defmodule MyModule do
      def echo(arg), do: IO.puts(arg)
    end

    test "echo was called with a float" do
      mock = mock_of MyModule

      mock.echo(10.5)

      assert_called mock.echo(Matchers.any(:float)) # passes
      assert_called mock.echo(Matchers.any(:integer)) # fails!
    end
  end
  ```
  """
  def any(type), do: {:matches, ElixirMock.Matchers.InBuilt.any(type)}

  @doc """
  A get-out-of-jail matcher that helps you literally match arguments that look like matchers

  When ElixirMock finds an argument that looks like `{:matches, other_thing}` in a function call verification, it will
  assume that `other_thing` is a function that is supposed to be used to match an argument. In the rare case that you
  need to match an argument that is literally `{:matches, other_thing}`, use this matcher. It will tell ElixirMock
  not to think about it as a matcher expression but rather as a literal value.

  Example:
  ```
  defmodule MyTest do
    use ExUnit.Case
    require ElixirMock
    import ElixirMock
    alias ElixirMock.Matchers

    defmodule MyModule do
      def echo(arg), do: IO.puts(arg)
    end

    test "echo was called with a float" do
      mock = mock_of MyModule

      mock.echo({:matches, 10})

      assert_called mock.echo(Matchers.literal({:matches, 10})) # passes
      assert_called mock.echo({:matches, 10}) # will blow up!
    end
  end
  ```
  """
  def literal(value), do: {:__elixir_mock__literal, value}

  @doc false
  def find_call({expected_fn, expected_args}, calls) do
    calls
    |> Enum.filter(fn {called_fn, _} -> called_fn == expected_fn end)
    |> Enum.any?(fn {_fn_name, args} -> match_call_args(expected_args, args) end)
  end

  defp match_call_args(expected_args, actual_args) when(length(actual_args) != length(expected_args)), do: false

  defp match_call_args(expected_args, actual_args) do
    Enum.zip(expected_args, actual_args)
    |> Enum.all?(fn {expected, actual} -> match_arg_pair(expected, actual) end)
  end

  defp match_arg_pair(expected, actual) do
    case expected do
      {:__elixir_mock__literal, explicit_literal} -> explicit_literal == actual
      {:matches, matcher} -> evaluate_matcher(matcher, actual)
      %{} -> deep_match(expected, actual)
      implicit_literal -> implicit_literal == actual
    end
  end

  defp evaluate_matcher(matcher, actual) when is_function(matcher) do
    matcher_arity = :erlang.fun_info(matcher)[:arity]
    error_message = "Use of bad function matcher '#{inspect matcher}' in match expression.
    Argument matchers must be functions with arity 1. This function has arity #{matcher_arity}"
    if  matcher_arity != 1 do
      raise ArgumentError, message: error_message
    end
    matcher.(actual)
  end

  defp evaluate_matcher(_, non_function_matcher) do
    error_message = "Use of non-function matcher '#{inspect non_function_matcher}' in match expression.
    Argument matchers must be in the form {:matches, &matcher_function/1}. If you expected your stubbed function to have
    been called with literal {:matches, #{inspect non_function_matcher}}, use ElixirMock.Matchers.literal({:matches, #{inspect non_function_matcher}})"
    raise ArgumentError, message: error_message
  end

  defp deep_match(%{} = _expected, actual) when not is_map(actual) , do: false

  defp deep_match(%{} = expected, %{} = actual) do
    Map.keys(actual)
    |> Enum.all?(&Map.has_key?(expected, &1))
    |> Kernel.and(all_kv_pairs_are_equal(expected, actual))
  end

  defp all_kv_pairs_are_equal(expected, actual) do
    expected
    |> Map.to_list
    |> Enum.all?(fn {expected_key, expected_val} ->
      if Map.has_key?(actual, expected_key),
         do: match_arg_pair(expected_val, Map.get(actual, expected_key)),
         else: false
    end)
  end
end