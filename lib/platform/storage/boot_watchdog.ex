defmodule Platform.Storage.BootWatchdog do
  @moduledoc """
  Restarts boot stages that stopped advancing.

  A staged boot tree cannot notice a stage that is alive but wedged: a process
  blocked in a `receive` never crashes, so every `max_restarts` above it stays
  unused. That is how a single blocked command in the internal PostgreSQL stage
  left a device without `Chat.Repo` and every USB drive stuck before `Decider` -
  no drive was recognised as main until someone rebooted it.

  So this watches from outside. Each staged tree is fingerprinted every tick;
  when a tree neither grows nor reaches its terminal child within its stall
  timeout, the deepest stage is dumped to the log and killed, and the
  supervisors get to do the recovery they had no reason to attempt.

  Scope is the staged boot itself - the internal DB tree up to the chunk
  pipeline, and each drive tree up to `Decider`. What a drive's scenario does
  after `Decider` is not watched here.
  """
  use GenServer
  use Toolbox.OriginLog

  alias Chat.Data.File.ChunkPipelineSupervisor
  alias Platform.App.DatabaseSupervisor
  alias Platform.Leds
  alias Platform.Storage.BootWatchdog.Tree
  alias Platform.UsbDrives.Decider

  @check_interval :timer.seconds(30)
  # Nothing in the internal DB tree legitimately takes this long.
  @internal_db_stall :timer.minutes(5)
  # `Healer` alone is allowed 430s for fsck on a big drive.
  @drive_stall :timer.minutes(12)
  # Kills that change nothing mean the stall is not a wedged process.
  @max_kills 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    interval = opts |> Keyword.get(:interval_ms, @check_interval)

    Process.send_after(self(), :check, interval)

    {:ok,
     %{
       interval: interval,
       groups: opts |> Keyword.get(:groups, default_groups()),
       seen: %{}
     }}
  end

  # Rebuilding the map every tick is also how roots that went away are forgotten.
  @impl true
  def handle_info(:check, %{interval: interval, groups: groups, seen: seen} = state) do
    Process.send_after(self(), :check, interval)

    groups
    |> Enum.flat_map(fn group -> group.roots.() |> Enum.map(&{&1, group}) end)
    |> Map.new(fn {root, group} -> {root, check_root(root, group, seen)} end)
    |> then(&{:noreply, %{state | seen: &1}})
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp check_root(root, group, seen) do
    tree = Tree.scan(root)
    fingerprint = Tree.fingerprint(tree)
    previous = seen |> Map.get(root, watched(fingerprint))

    cond do
      Tree.complete?(tree, group.terminal) -> watched(fingerprint)
      fingerprint != previous.fingerprint -> watched(fingerprint)
      stalled?(previous, group.stall_ms) -> unstick(tree, root, group, previous)
      true -> previous
    end
  end

  defp watched(fingerprint), do: %{fingerprint: fingerprint, since: now(), kills: 0}

  defp stalled?(%{since: since}, stall_ms), do: now() - since >= stall_ms

  defp unstick(_tree, root, group, %{kills: kills} = previous) when kills >= @max_kills do
    log(
      "#{group.name} #{inspect(root)} is still stalled after #{kills} restarts - leaving it alone",
      :error
    )

    Leds.blink_alarm()

    %{previous | since: now()}
  end

  defp unstick(tree, root, group, %{kills: kills} = previous) do
    workers = Tree.deepest_workers(tree)

    log(
      "#{group.name} #{inspect(root)} made no progress for #{div(group.stall_ms, 1000)}s" <>
        " - restarting its stuck stage",
      :error
    )

    workers |> Enum.each(&log_worker_info/1)
    workers |> Enum.each(fn {_id, pid} -> Process.exit(pid, :kill) end)

    %{previous | since: now(), kills: kills + 1}
  end

  # The stacktrace is the whole point of killing from here rather than from a
  # supervisor: it names the call that never returned.
  defp log_worker_info({id, pid}) do
    pid
    |> Process.info([:registered_name, :status, :message_queue_len, :current_stacktrace])
    |> case do
      nil ->
        log("stuck stage #{inspect(id)} #{inspect(pid)} is gone already", :warning)

      info ->
        log("stuck stage #{inspect(id)} #{inspect(pid)}: #{inspect(info, pretty: true)}", :error)
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp default_groups do
    [
      %{
        name: :internal_db,
        roots: &internal_db_roots/0,
        terminal: ChunkPipelineSupervisor,
        stall_ms: @internal_db_stall
      },
      %{
        name: :drive,
        roots: &drive_roots/0,
        terminal: Decider,
        stall_ms: @drive_stall
      }
    ]
  end

  defp internal_db_roots, do: DatabaseSupervisor |> Process.whereis() |> List.wrap()

  defp drive_roots do
    Platform.Drives
    |> Tree.children()
    |> Enum.flat_map(fn
      {_id, pid, _type, _modules} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end
end
