defmodule Platform.Emulator.Drive.Mounter do
  @moduledoc """
  Does nothing, but tree building
  """
  use GracefulGenServer, timeout: :timer.minutes(1)

  require Logger

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      device: opts |> Keyword.fetch!(:device),
      path: opts |> Keyword.fetch!(:at),
      task_supervisor: opts |> Keyword.fetch!(:task_in),
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under),
      task_ref: nil
    }
    |> tap(fn _ -> Process.send_after(self(), :mounted, 100) end)
  end

  @impl true

  def on_msg(:mounted, %{next_specs: next_specs, next_supervisor: next_supervisor} = state) do
    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(reason, %{path: path, task_supervisor: _task_supervisor}) do
    "mount cleanup #{path} #{inspect(reason)}" |> Logger.warning()
  end
end
