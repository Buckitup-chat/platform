defmodule Platform.Storage.BootWatchdog.Tree do
  @moduledoc """
  Read-only view of a staged supervision tree, for `Platform.Storage.BootWatchdog`.

  Every supervisor call here is bounded. The trees this walks are exactly the
  ones that can be wedged, and `Supervisor.which_children/1` waits forever -
  inspecting a stuck tree must never stick the inspector to it.
  """

  @call_timeout :timer.seconds(2)

  @doc """
  Snapshot of everything running under `root`.

  A staged tree grows one nesting level per completed stage, so the workers of
  the deepest level are the stage currently in progress.
  """
  def scan(root),
    do: visit(%{ids: [], size: 0, depth: 0, workers: []}, root, 0)

  @doc """
  Children of a supervisor, or `[]` when it is gone or does not answer.
  """
  def children(supervisor) do
    GenServer.call(supervisor, :which_children, @call_timeout)
  catch
    :exit, _reason -> []
  end

  @doc """
  Changes whenever the tree gains, loses or replaces a child.

  Deliberately ignores pids: a stage crash-looping in place is the supervisors'
  problem, not a stall.
  """
  def fingerprint(%{ids: ids, size: size}), do: {size, ids |> Enum.sort() |> :erlang.phash2()}

  @doc """
  True once the tree contains the child that ends its staged startup.
  """
  def complete?(%{ids: ids}, terminal_id), do: terminal_id in ids

  @doc """
  Workers of the deepest stage, as `{id, pid}` - where a tree that stopped
  growing is stuck.
  """
  def deepest_workers(%{workers: workers}), do: workers

  defp visit(acc, supervisor, depth) do
    supervisor
    |> children()
    |> Enum.reduce(acc, fn {id, pid, type, _modules}, acc ->
      %{acc | ids: [id | acc.ids], size: acc.size + 1}
      |> descend(id, pid, type, depth)
    end)
  end

  defp descend(acc, _id, pid, _type, _depth) when not is_pid(pid), do: acc
  defp descend(acc, _id, pid, :supervisor, depth), do: visit(acc, pid, depth + 1)
  defp descend(acc, id, pid, :worker, depth), do: collect_worker(acc, id, pid, depth)

  defp collect_worker(%{depth: deepest} = acc, _id, _pid, depth) when depth < deepest, do: acc

  defp collect_worker(%{depth: deepest} = acc, id, pid, depth) when depth == deepest,
    do: %{acc | workers: [{id, pid} | acc.workers]}

  defp collect_worker(acc, id, pid, depth),
    do: %{acc | depth: depth, workers: [{id, pid}]}
end
