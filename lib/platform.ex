defmodule Platform do
  @moduledoc """
  Documentation for Platform.
  """

  def start_next_stage(dynamic_supervisor, specs) do
    %{
      id: make_ref(),
      start:
        {Supervisor, :start_link,
         [specs, [strategy: :rest_for_one, max_restarts: 1, max_seconds: 5]]}
    }
    |> then(&DynamicSupervisor.start_child(dynamic_supervisor, &1))
  end

  def use_next_stage(name) do
    {DynamicSupervisor, name: name, strategy: :one_for_one, max_restarts: 0, max_seconds: 5}
  end

  def use_task(name) do
    {Task.Supervisor, name: name}
  end
end
