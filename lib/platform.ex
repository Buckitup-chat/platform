defmodule Platform do
  @moduledoc """
  Documentation for Platform.
  """

  def start_next_stage(dynamic_supervisor, specs) do
    %{
      id: make_ref(),
      start:
        {Supervisor, :start_link,
         [specs, [strategy: :rest_for_one, max_restarts: 1, max_seconds: 50]]},
      shutdown: calc_exit_time(specs),
      type: :supervisor
    }
    |> then(&DynamicSupervisor.start_child(dynamic_supervisor, &1))
  end

  def use_next_stage(name, exit_time \\ 5000) do
    {DynamicSupervisor, name: name, strategy: :one_for_one, max_restarts: 0}
    |> exit_takes(exit_time)
  end

  def use_task(name) do
    {Task.Supervisor, name: name}
  end

  def prepare_stages(specs, prefix) do
    specs
    |> Enum.reject(&is_nil/1)
    |> build_tree(prefix)
  end

  def calc_exit_time(specs) do
    specs
    |> Enum.map(fn
      %{shutdown: exit_time} -> exit_time
      _ -> 5000
    end)
    |> Enum.sum()
  end

  def exit_takes(x, milliseconds) do
    Supervisor.child_spec(x, shutdown: milliseconds)
  end

  defp build_tree(specs, prefix, prepared \\ []) do
    case specs do
      [] ->
        prepared

      [{:stage, _name, x}] ->
        prepared ++ [x]

      [{:stage, name, module} | rest] when is_atom(module) ->
        prepared ++ build_next_stage(prefix, name, {module, []}, rest)

      [{:stage, name, {module, args}} | rest] ->
        prepared ++ build_next_stage(prefix, name, {module, args}, rest)

      [{:stage, name, %{start: _} = spec} | rest] ->
        prepared ++ build_next_stage(prefix, name, spec, rest)

      [spec] ->
        prepared ++ [spec]

      [spec | rest] ->
        build_tree(rest, prefix, prepared ++ [spec])
    end
  end

  defp build_next_stage(prefix, name, spec, rest) do
    next_tree = build_tree(rest, prefix)
    next_exit_time = calc_exit_time(next_tree)

    stage_name = make_stage_name(prefix, name)

    [use_next_stage(stage_name, next_exit_time), inject_next_stage(spec, stage_name, next_tree)]
  end

  defp inject_next_stage(spec, stage_name, next_tree) do
    case spec do
      %{start: {module, func, [args]}} ->
        spec
        |> Map.put(
          :start,
          {module, func, [args |> Keyword.merge(next: [under: stage_name, run: next_tree])]}
        )

      {module, args} ->
        {module, args |> Keyword.merge(next: [under: stage_name, run: next_tree])}
    end
  end

  defp make_stage_name(prefix, name) when is_atom(prefix),
    do: prefix |> Atom.to_string() |> String.slice(7..-1) |> make_stage_name(name)

  defp make_stage_name(prefix, name) when is_atom(name),
    do: name |> Atom.to_string() |> String.slice(7..-1) |> then(&make_stage_name(prefix, &1))

  defp make_stage_name(_prefix, {:via, _, _} = via), do: via
  defp make_stage_name(prefix, name), do: :"Elixir.#{prefix}.#{name}"
end
