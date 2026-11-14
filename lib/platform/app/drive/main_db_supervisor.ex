defmodule Platform.App.Drive.MainDbSupervisor do
  @moduledoc """
  Main DB device mount
  """
  use Supervisor
  use Toolbox.OriginLog

  import Platform

  alias Chat.Storage.Unit
  alias Platform.Storage.Bouncer
  alias Platform.Storage.MainPlan

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg,
      name: __MODULE__,
      max_restarts: 1,
      max_seconds: 15
    )
  end

  @impl true
  def init([device, _path, _pg_opts]) do
    log("start", :debug)

    unit = Unit.usb(device, :main)
    full_path = Unit.path(unit, :cub_db)

    [
      dir_creator(full_path),
      {Chat.Db.MainDbSupervisor, full_path} |> exit_takes(20_000),
      {Bouncer, db: Chat.Db.MainDb, role: :main},
      # Registers the main unit and is the upload writer once the plan makes main the Default
      {Chat.Data.File.ChunkPipelineSupervisor, unit: unit},
      # Attach plan on start, eject plan on exit: stops links + switches Default back
      {MainPlan, device: device} |> exit_takes(25_000)
    ]
    |> tap(fn specs ->
      specs
      |> calc_exit_time()
      |> then(&log("exit time #{inspect(&1)}", :debug))
    end)
    |> Supervisor.init(strategy: :rest_for_one, max_restarts: 1, max_seconds: 5)
  end

  defp dir_creator(path), do: {Task, fn -> File.mkdir_p!(path) end}
end
