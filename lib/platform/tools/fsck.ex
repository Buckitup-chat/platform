defmodule Platform.Tools.Fsck do
  @moduledoc "Fsck wrapper"

  def vfat(device) do
    fn ->
      {:spawn, "fsck.vfat /dev/" <> device}
      |> Port.open([:binary])
      |> process_messages()
    end
    |> Task.async()
    |> Task.await(15 * 60 * 1000)
  end

  @choise_prompt_start "[12"
  @first_option_select "1\n"

  defp process_messages(port) do
    receive do
      {_port, {:data, str}} ->
        str
        |> String.split("\n", trim: true)
        |> List.last()
        |> case do
          @choise_prompt_start <> _ -> Port.command(port, @first_option_select)
          _ -> nil
        end

        process_messages(port)

      _ ->
        process_messages(port)
    after
      500 ->
        case Port.info(port) do
          nil -> :ok
          _ -> process_messages(port)
        end
    end
  end
end
