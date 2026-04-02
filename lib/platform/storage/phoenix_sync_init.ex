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

    # Reinitialize Phoenix.Sync with the now-ready database
    reinit_phoenix_sync("on_init")

    if Keyword.get(opts, :init_peers) do
      Chat.NetworkSynchronization.init_electric_peers()
    end

    # Start the next stage if configured (used in DatabaseSupervisor)
    case Keyword.get(opts, :next) do
      nil ->
        :ok

      next_opts ->
        next_supervisor = next_opts |> Keyword.fetch!(:under)
        next_specs = next_opts |> Keyword.fetch!(:run)
        Platform.start_next_stage(next_supervisor, next_specs)
    end

    %{task_in: task_supervisor}
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
