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

  def prepare_stages(specs, prefix) do
    specs
    |> Enum.reject(&is_nil/1)
    |> build_tree(prefix)
  end

  defp build_tree(specs, prefix, prepared \\ []) do
    case specs do
      [] ->
        prepared

      [{:stage, name, {module, args}}] ->
        prepared ++ [{module, args}]

      [{:stage, name, {module, args}} | rest] ->
        stage_name = make_stage_name(prefix, name)

        prepared ++
          [use_next_stage(stage_name)] ++
          [
            {module,
             args |> Keyword.merge(next: [under: stage_name, run: build_tree(rest, prefix)])}
          ]

      [spec] ->
        prepared ++ [spec]

      [spec | rest] ->
        build_tree(rest, prefix, prepared ++ [spec])
    end
  end

  defp make_stage_name(prefix, name) when is_atom(prefix),
    do: prefix |> Atom.to_string() |> String.slice(7..-1) |> make_stage_name(name)

  defp make_stage_name(prefix, name) when is_atom(name),
    do: name |> Atom.to_string() |> String.slice(7..-1) |> then(&make_stage_name(prefix, &1))

  defp make_stage_name(prefix, name), do: :"Elixir.#{prefix}.#{name}"
end
