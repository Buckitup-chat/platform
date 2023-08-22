defmodule Platform.App.Media.Helpers do
  @moduledoc "Media functionality helpers"

  @spec terminate_stages() :: :ok | {:error, :not_found}
  def terminate_stages() do
    Platform.App.Media.Supervisor
    |> Supervisor.terminate_child(Platform.App.MediaStages.Healing)
  end
end
