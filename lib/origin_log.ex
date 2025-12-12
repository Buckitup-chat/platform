defmodule OriginLog do
  @moduledoc """
  A macro module that provides logging with automatic prefix generation.

  The prefix is derived from the using module's name, converting it to a
  lowercase, bracket-wrapped format.

  ## Example

      defmodule Platform.Storage.Logic do
        use OriginLog

        def some_function do
          log("Processing data", :info)
          # Logs: [platform][storage][logic] Processing data
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      require Logger

      defp log(iolist, level) do
        message = OriginLog.normalize_iolist(iolist)

        Logger.log(level, [unquote(generate_prefix(__CALLER__.module)), message])
      end
    end
  end

  @doc false
  def generate_prefix(module) do
    module
    |> Module.split()
    |> Enum.join(".")
    |> then(&"[_#{&1}_] ")
  end

  @doc false
  def normalize_iolist(term), do: do_normalize_iolist(term)

  defp do_normalize_iolist(term) do
    case term do
      binary when is_binary(binary) ->
        binary

      [] ->
        []

      [a] when is_integer(a) and a >= 0 and a <= 255 ->
        <<a>>

      [a, b]
      when is_integer(a) and a >= 0 and a <= 255 and is_integer(b) and b >= 0 and b <= 255 ->
        <<a, b>>

      [a, b, c | _]
      when is_integer(a) and a >= 0 and a <= 255 and is_integer(b) and b >= 0 and b <= 255 and
             is_integer(c) and c >= 0 and c <= 255 ->
        term

      [head | tail] ->
        [do_normalize_iolist(head) | do_normalize_iolist(tail)]

      _ ->
        inspect(term)
    end
  end
end
