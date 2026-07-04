defmodule Platform do
  @moduledoc """
  Documentation for `Platform`.
  """

  @doc """
  Hello world.

  ## Examples

      iex> Platform.hello()
      :world

  """
  def hello do
    :world
  end

  #############################################################################

  defdelegate start_next_stage(dynamic_supervisor, specs), to: Toolbox.StagedSupervisor
  defdelegate use_next_stage(name, exit_time \\ 5000), to: Toolbox.StagedSupervisor
  defdelegate use_task(name), to: Toolbox.StagedSupervisor
  defdelegate prepare_stages(specs, prefix), to: Toolbox.StagedSupervisor
  defdelegate calc_exit_time(specs), to: Toolbox.StagedSupervisor
  defdelegate exit_takes(x, milliseconds), to: Toolbox.StagedSupervisor
end
