defmodule GracefulGenServer do
  @moduledoc """
    Handles init and terminate
  """

  @callback on_init(args :: any) :: any
  @callback on_exit(reason :: any, state :: any) :: any
  @callback on_msg(msg :: any, state :: any) ::
              {:noreply, new_state}
              | {:noreply, new_state, timeout | :hibernate | {:continue, continue_arg :: term}}
              | {:stop, reason :: term, new_state}
            when new_state: term

  @optional_callbacks on_msg: 2

  defmacro __using__(start_opts) do
    quote do
      @behaviour GracefulGenServer
      use GenServer

      alias GracefulGenServer.Functions, as: Graceful

      def start_link(args) do
        GenServer.start_link(__MODULE__, args, unquote(Macro.escape(start_opts)))
      end

      @impl true
      def init(args), do: Graceful.init(args, do: &on_init/1, as: __MODULE__)

      @impl true
      def handle_info(msg, state),
        do:
          Graceful.handle_info(msg, state,
            on_exit: &on_exit/2,
            on_msg: &on_msg/2,
            as: __MODULE__
          )

      @impl true
      def terminate(reason, state),
        do: Graceful.terminate(reason, state, on_exit: &on_exit/2, as: __MODULE__)

      @doc false
      def on_msg(_msg, state), do: {:noreply, state}

      defoverridable on_msg: 2
    end
  end

  defmodule Functions do
    require Logger

    @doc """
    This function initiates genserver. 

    Keyword options:
      - `:do` - callback invoked with init args. Should return init state
      - `:as` - optional name, triggering logging
    """
    def init(args, opts) do
      action = Keyword.fetch!(opts, :do)
      Process.flag(:trap_exit, true)

      args
      |> tap(&log_starting(&1, opts[:as]))
      |> then(action)
      |> tap(&log_started(&1, opts[:as]))
      |> ok()
    end

    @doc """
    Termination handler.  

    Keyword options:
      - `:on_exit` - optional callback invoked when process exits. `on_exit(reason, state)`
      - `:as` - optional name, triggering logging
    """
    def terminate(reason, state, opts) do
      log_exiting({reason, :terminate}, opts[:as])

      if is_function(opts[:on_exit]) do
        opts[:on_exit].(reason, state)
      end

      state
    end

    @doc """
    Handle info message.

    Keyword options:
      - `:on_msg` - optional callback invoked when message is received. `on_msg(msg, state)`. Should return `handle_info` result.
      - `:on_exit` - optional callback invoked when process exits. `on_exit(reason, state)`
      - `:as` - optional name, triggering logging
    """
    def handle_info(msg, state, opts) do
      case msg do
        {:EXIT, from, _} when is_port(from) ->
          state |> noreply()

        {:EXIT, from, reason} ->
          log_and_exit({from, reason}, state, opts[:on_exit], opts[:as])

        msg ->
          route_message_handling(msg, state, opts[:on_msg])
      end
    end

    defp log_and_exit({from, reason}, state, on_exit, as) do
      log_exiting({from, reason}, as)

      if is_function(on_exit) do
        on_exit.(reason, state)
      end

      {:stop, reason, state}
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

    defp log_exiting({from, reason}, who) do
      if who do
        ["exiting ", who, " from ", inspect(from), ": ", inspect(reason, pretty: true)]
        |> Logger.info()
      end
    end
  end
end
