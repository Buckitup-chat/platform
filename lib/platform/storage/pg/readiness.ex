defmodule Platform.Storage.Pg.Readiness do
  @moduledoc """
  Polls a PostgreSQL instance until it answers on its port.

  Used by `Platform.Storage.Pg.Daemon` once the server has been spawned. The
  polling itself runs in a supervised task: a probe that crashes or hangs — e.g.
  `:epipe` when a connection check races a network reconfiguration — is reported
  back as `{:error, _}` for the calling stage to retry, instead of taking it down.
  """
  use Toolbox.OriginLog

  alias Platform.Tools.Postgres

  # 30 attempts (60 seconds total) leaves room for slow SD cards
  @max_attempts 30
  @check_interval_ms 2000
  # Backstop well above the 60s of polling: a single probe shells out to psql
  # without a timeout of its own, so a wedged one has to be killed from here.
  @poll_timeout :timer.minutes(2)

  @doc """
  Wait until PostgreSQL answers on `pg_port`, polling from a task under `task_supervisor`.

  Returns `:ok`, or `{:error, reason}` when the probes ran out, crashed or had
  to be killed - all of them retryable by the calling stage.
  """
  def await(task_supervisor, pg_port) do
    task = Task.Supervisor.async_nolink(task_supervisor, fn -> poll(pg_port, @max_attempts) end)

    case Task.yield(task, @poll_timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> {:error, :poll_timeout}
    end
  end

  defp poll(pg_port, attempts_left) do
    cond do
      attempts_left <= 0 ->
        log("PostgreSQL failed to start after #{@max_attempts} attempts", :error)
        {:error, :not_responding}

      Postgres.server_running?(pg_port: pg_port) ->
        log("PostgreSQL responding on port #{pg_port}", :debug)
        :ok

      true ->
        log(
          "Waiting for PostgreSQL on port #{pg_port} (#{attempts_left} attempts remaining)",
          :debug
        )

        Process.sleep(@check_interval_ms)
        poll(pg_port, attempts_left - 1)
    end
  end
end
