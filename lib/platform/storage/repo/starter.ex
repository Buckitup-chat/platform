defmodule Platform.Storage.Repo.Starter do
  @moduledoc """
  Stage module for starting Chat.Repo with a dynamic name.
  This is a long-running stage that keeps the repo alive and propagates to next stage.
  """
  use GracefulGenServer, timeout: :timer.minutes(3)
  use Toolbox.OriginLog

  alias Chat.Storage.Link
  alias Chat.Storage.Pg.LogicalReplicator
  alias Chat.Storage.Role

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      repo_name: opts |> Keyword.fetch!(:name),
      port: opts |> Keyword.fetch!(:port),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      repo_pid: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          repo_name: repo_name,
          port: port,
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    log("Starting #{inspect(repo_name)} on port #{port}", :info)

    {:ok, pid} =
      Application.get_env(:chat, Chat.Repo)
      |> Keyword.put(:port, port)
      |> repo_name.start_link()

    cleanup_stale_replication(repo_name)

    log("Chat.Repo started successfully, starting next stage", :info)
    Platform.start_next_stage(next_supervisor, next_specs)

    {:noreply, %{state | repo_pid: pid}}
  end

  @impl true
  def on_exit(_reason, %{repo_name: repo_name}) do
    log("Repo starter stage exiting for #{inspect(repo_name)}", :info)
    :ok
  end

  # Leftovers of links from a previous session
  defp cleanup_stale_replication(repo) do
    if repo == Chat.Repo,
      do: LogicalReplicator.disable_subscription_if_exists(repo, stale_subscription())

    drop_stale_slots(repo)
  end

  defp stale_subscription, do: Link.name({:main, :internal}, :subscription)

  # A physically ejected `to` never drops its slot on `from`, and an inactive
  # slot pins WAL forever. Active ones belong to a link that is still up.
  defp drop_stale_slots(repo) do
    "SELECT slot_name FROM pg_replication_slots WHERE NOT active AND slot_name = ANY($1)"
    |> repo.query([link_slot_names()])
    |> case do
      {:ok, %{rows: rows}} ->
        rows |> Enum.each(fn [slot] -> LogicalReplicator.drop_slot_if_exists(repo, slot) end)

      {:error, reason} ->
        log("stale slots lookup failed: #{inspect(reason)}", :warning)
    end
  end

  defp link_slot_names do
    roles = Role.all() |> Enum.filter(&(:pg in Role.capabilities(&1)))
    for from <- roles, to <- roles, from != to, do: Link.name({from, to}, :slot)
  end
end
