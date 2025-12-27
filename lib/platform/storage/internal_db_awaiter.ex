defmodule Platform.Storage.InternalDbAwaiter do
  @moduledoc """
  Waits for internal databases (CubDB and PostgreSQL) to be ready.
  Uses Process.send_after for infinite polling once per second.
  """
  use GracefulGenServer
  use OriginLog

  @check_interval_ms 1_000

  @impl true
  def on_init(opts) do
    task_supervisor = opts |> Keyword.fetch!(:task_in)
    next_opts = opts |> Keyword.fetch!(:next)
    next_supervisor = next_opts |> Keyword.fetch!(:under)
    next_specs = next_opts |> Keyword.fetch!(:run)

    send(self(), :check)

    %{
      task_in: task_supervisor,
      next: {next_specs, next_supervisor},
      attempt: 1
    }
  end

  @impl true
  def on_msg(:check, state) do
    cubdb_ready = check_cubdb_ready()
    pg_ready = check_pg_ready()

    if cubdb_ready and pg_ready do
      log("Internal DBs ready (CubDB=#{cubdb_ready}, PG=#{pg_ready})", :info)
      send(self(), :ready)
    else
      log(
        "Waiting for internal DBs (attempt #{state.attempt}, CubDB=#{cubdb_ready}, PG=#{pg_ready})",
        :debug
      )

      Process.send_after(self(), :check, @check_interval_ms)
    end

    {:noreply, %{state | attempt: state.attempt + 1}}
  end

  def on_msg(:ready, %{next: {next_specs, next_supervisor}} = state) do
    Chat.Sync.DbBrokers.refresh()
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  defp check_cubdb_ready do
    Process.whereis(Chat.Db.InternalDb) != nil
  end

  defp check_pg_ready do
    Chat.Repo.query("SELECT 1", [])
    true
  rescue
    error ->
      log("Chat.Repo PG not ready: #{inspect(error)}", :warn)
      false
  catch
    :exit, reason ->
      log("Chat.Repo PG exited during readiness check: #{inspect(reason)}", :warn)
      false
  end

  @impl true
  def on_exit(_reason, _state), do: :ok
end
