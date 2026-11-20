defmodule Platform.Storage.MainPlan do
  @moduledoc """
  Main drive scenario as link plans, run by `Chat.Storage.PlanRunner`.

  On start it runs `:main_attach`; whatever ends it (eject, crash, restart) runs
  `:main_eject` in `on_exit`. The attach runner is linked, so on exit it stops every
  link it still runs before the eject plan starts.

  Options: `device:` (required).

  See `chat/docs/pq/reqs/files/pq_storage_units.done.md` §2.7.3–2.7.5.
  """

  use GracefulGenServer
  use Toolbox.OriginLog

  import Chat.Storage.Link, only: [~>: 2]

  alias Chat.Storage.Default
  alias Chat.Storage.PlanRunner
  alias Chat.Storage.Unit
  alias Chat.Storage.Units
  alias Platform.Leds

  @check_ms 500

  @spec plan(:main_attach | :main_eject, Unit.t(), Unit.t()) :: [PlanRunner.step()]
  def plan(:main_attach, internal, main) do
    [
      {:bootstrap, internal ~> main},
      # keep the drive fresh while internal is still the Default
      {:replicate, internal ~> main},
      # pull data only the drive has back to internal
      {:bootstrap, main ~> internal},
      {:stop, internal ~> main},
      # internal becomes a mirror of main
      {:replicate, main ~> internal},
      {:switch_default, main}
    ]
  end

  def plan(:main_eject, internal, main),
    do: [{:stop, main ~> internal}, {:switch_default, internal}]

  @impl GracefulGenServer
  def on_init(opts) do
    device = Keyword.fetch!(opts, :device)
    internal = registered(:internal, Unit.internal())
    main = registered(:main, Unit.usb(device, :main))

    Leds.blink_write()
    {:ok, runner} = start_plan(:main_attach, internal, main)
    schedule_check()

    %{internal: internal, main: main, runner: runner, attached?: false}
  end

  @impl GracefulGenServer
  def on_msg(:check, %{runner: runner} = state) do
    case PlanRunner.info(runner) do
      %{status: :running} ->
        schedule_check()
        {:noreply, state}

      %{status: status} ->
        log("attach #{inspect(status)}", if(status == :done, do: :info, else: :error))
        Leds.blink_done()
        # Drive copy re-polls for the missing_chunks the bootstraps queued
        Phoenix.PubSub.broadcast(
          Chat.PubSub,
          "chunk_pipeline",
          {:chunk_pipeline, :pg_diff_copied}
        )

        {:noreply, %{state | attached?: true}}
    end
  end

  def on_msg(_msg, state), do: {:noreply, state}

  @impl GracefulGenServer
  def on_exit(reason, %{internal: internal, main: main, runner: runner}) do
    log("eject #{inspect(reason)}", :warning)
    stop(runner)

    {:ok, eject} = start_plan(:main_eject, internal, main)
    await_done(eject)
    stop(eject)

    Leds.blink_done()
    log("eject done", :warning)
  end

  defp start_plan(name, internal, main),
    do: PlanRunner.start_link(plan: plan(name, internal, main), switch_default: &switch_default/1)

  defp switch_default(%Unit{id: id} = unit) do
    case Default.unit() do
      %Unit{id: ^id} -> :ok
      _ -> Default.switch_to(unit)
    end
  end

  # The registered unit carries the PG system id the links stamp on missing_chunks
  defp registered(role, fallback) do
    case Units.by_role(role) do
      {:ok, unit} -> unit
      :error -> fallback
    end
  end

  defp await_done(runner) do
    case PlanRunner.info(runner) do
      %{status: :running} ->
        Process.sleep(@check_ms)
        await_done(runner)

      %{status: status} ->
        status
    end
  end

  defp stop(runner), do: if(Process.alive?(runner), do: GenServer.stop(runner))

  defp schedule_check, do: Process.send_after(self(), :check, @check_ms)
end
