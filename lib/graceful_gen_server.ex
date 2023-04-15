defmodule GracefulGenServer do
  @moduledoc """
    Handles init and terminate
  """

  defmodule Functions do
    require Logger

    def init(args, opts) do
      Process.flag(:trap_exit, true)

      args
      |> tap(&log_starting(&1, opts[:as])
      |> then(opts.do)
      |> tap(&log_started(&1, opts[:as]))
      |> ok()
    end

    def terminate(reason, state, opts) do
    end

    def handle_info(msg, state, opts) do
      case msg do
        {:EXIT, from, _} when is_port(from) ->
          state |> noreply()
        {:EXIT, from, reason} -> 
          log_and_exit({from, reason}, state, opts.on_exit, opts[:as])
        msg ->
          route_message_handling(msg, state, opts[:on_msg]) 
      end
    end

    defp route_message_handling(_, state, nil), do: noreply(state)
    defp route_message_handling(msg, state, action), do: action.(msg, state)

    defp ok(x), do: {:ok, x}
    defp noreply(x), do: {:noreply, x}

    defp log_starting(args, who) do
      if who do
        ["starting ", who, inspect(args, pretty: true)]
        |> Logger.info()
      end
    end

    defp log_started(state, who) do
      if who do
        ["started ", who, inspect(state, pretty: true)]
        |> Logger.debug()
      end
    end
    defp log_exiting() do
    Logger.info("exiting #{__MODULE__} #{inspect(self())} from #{inspect(from)}")
      
    end
  end
end
