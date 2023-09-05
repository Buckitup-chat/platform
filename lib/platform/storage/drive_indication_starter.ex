defmodule Platform.Storage.DriveIndicationStarter do
  @moduledoc false
  use GracefulGenServer

  alias Platform.Storage.DriveIndication

  @impl true
  def on_init(opts) do
    next = opts |> Keyword.fetch!(:next)

    %{
      next_specs: next |> Keyword.fetch!(:run),
      next_supervisor: next |> Keyword.fetch!(:under)
    }
    |> tap(fn _ -> send(self(), :start) end)
  end

  @impl true
  def on_msg(
        :start,
        %{
          next_specs: next_specs,
          next_supervisor: next_supervisor
        } = state
      ) do
    DriveIndication.drive_init()
    :timer.sleep(250)
    DriveIndication.drive_reset()
    :timer.sleep(250)
    DriveIndication.drive_accepted()

    Platform.start_next_stage(next_supervisor, next_specs)
    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _device), do: :nothing
end
