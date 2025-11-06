defmodule Platform.Storage.Pg.DbCreator do
  @moduledoc """
  Step module for ensuring a PostgreSQL database exists.
  Runs once to create the specified database if it doesn't exist.
  """
  use GracefulGenServer, timeout: :timer.minutes(1)

  require Logger

  alias Platform.Tools.Postgres

  @impl true
  def on_init(opts) do
    Logger.warning("--------------- init DbCreator: #{inspect(opts)}")
    next = opts |> Keyword.fetch!(:next)

    %{
      db_name: opts |> Keyword.fetch!(:db_name),
      pg_port: opts |> Keyword.fetch!(:pg_port),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          db_name: db_name,
          pg_port: pg_port,
          task_supervisor: task_supervisor
        } = state
      ) do
    Logger.warning("--------------- starting DB creator")

    %{ref: ref} =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        try do
          Logger.info("DbCreator '#{db_name}' started")
          x = Postgres.ensure_db_exists(db_name, pg_port: pg_port)
          Logger.warning("DbCreator '#{db_name}' returned #{inspect(x)}")
        catch
          type, reason ->
            Logger.error("DbCreator '#{db_name}' failed with #{inspect({type, reason})}")
        end
        |> inspect()
        |> Logger.warning()
      end)

    Logger.warning("--------------- started DB creator task")

    {:noreply, %{state | task_ref: ref}}
  end

  def on_msg({ref, _result}, %{task_ref: ref, db_name: db_name} = state) do
    Process.demonitor(ref, [:flush])
    Logger.info("Database '#{db_name}' ready, starting next stage")
    send(self(), :db_ready)
    {:noreply, state}
  end

  def on_msg(:db_ready, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(reason, state) do
    Logger.warning("Exitiing DbCreator: #{inspect({reason, state})}")
  end
end
