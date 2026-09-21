defmodule Platform.DeviceId do
  @moduledoc "Device identity from hardware serial number and model"

  @behaviour Chat.DeviceId

  @impl true
  def id do
    with {:ok, content} <- read_cpuinfo(),
         {:ok, model} <- parse_field(content, "Model"),
         {:ok, serial} <- parse_field(content, "Serial") do
      "#{short_model(model)}_#{serial}"
    else
      _ -> Chat.DeviceId.Default.id()
    end
  end

  defp read_cpuinfo, do: File.read("/proc/cpuinfo")

  @doc false
  def parse_field(content, field) do
    content
    |> String.split("\n")
    |> Enum.find_value(:error, fn line ->
      with [key, value] <- String.split(line, ":", parts: 2),
           true <- String.trim(key) == field do
        {:ok, String.trim(value)}
      else
        _ -> nil
      end
    end)
  end

  defp short_model(model) do
    cond do
      model =~ "Raspberry Pi 5" -> "RPi5"
      model =~ "Raspberry Pi 4" -> "RPi4"
      model =~ "Raspberry Pi 3" -> "RPi3"
      model =~ "Raspberry Pi" -> "RPi"
      model =~ "MangoPi" -> "MangoPi"
      true -> model |> String.split() |> Enum.take(2) |> Enum.join("")
    end
  end
end
