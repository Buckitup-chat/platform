defmodule Platform.Storage.PhoenixSyncInit do
  @moduledoc """
  Initializes Phoenix.Sync after the PostgreSQL database is ready.

  Phoenix.Sync starts at application boot before PostgreSQL is running,
  causing the Electric embedded stack to fail. This module is called after
  the database is ready to properly initialize the Electric stack.

  Used in two contexts:
  1. After internal database migrations (initial boot)
  2. After USB database switch (USB insert/eject)

  Calls reinit on both init and exit to handle repo changes in both directions.
  """
  use GracefulGenServer
  use Toolbox.OriginLog

  @impl true
  def on_init(opts) do
    task_supervisor = Keyword.get(opts, :task_in)
    next = Keyword.get(opts, :next)
    init_peers = Keyword.get(opts, :init_peers, false)

    %{task_in: task_supervisor, next: next, init_peers: init_peers}
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl GracefulGenServer
  def on_msg(:start, state) do
    reinit_phoenix_sync("on_init")

    if state.init_peers do
      Chat.NetworkSynchronization.init_electric_peers()
    end

    if state.next, do: Platform.start_next_stage(state.next[:under], state.next[:run])
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    # Reinit on exit to handle repo revert (e.g., USB ejected)
    reinit_phoenix_sync("on_exit")
  end

  defp reinit_phoenix_sync(context) do
    try do
      log("Reinitializing Phoenix.Sync (#{context})", :info)
      Chat.PhoenixSyncReinit.reinit()
    catch
      kind, error ->
        log("Phoenix.Sync reinit failed (#{context}): #{kind} #{inspect(error)}", :error)
    end
  end
end
