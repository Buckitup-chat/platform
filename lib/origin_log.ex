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
        Logger.log(level, [unquote(generate_prefix(__CALLER__.module)) | iolist])
      end
    end
  end

  @doc false
  def generate_prefix(module) do
    module
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&("[#{&1}]"))
    |> Enum.join()
    |> then(&(&1 <> " "))
  end
end
