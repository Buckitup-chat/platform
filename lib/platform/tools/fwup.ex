defmodule Platform.Tools.Fwup do
  @moduledoc "fwup tasks"

  use Toolbox.OriginLog

  @firmware_source_path "/data/platform.fw"

  def upgrade(binary) do
    prepare_source(binary)

    case run_upgrade() do
      {_, 0} ->
        log("firmware upgrade succeeded", :debug)

        schedule_source_cleanup_and_reboot()
        :ok

      {output, status} ->
        log(
          "firmware upgrade failed with status #{status}. Error output: #{output}",
          :debug
        )

        schedule_source_cleanup()
        :error
    end
  end

  def upgrade_from_file(path) do
    case run_upgrade(path) do
      {_, 0} ->
        log("firmware upgrade succeeded", :debug)
        schedule_source_cleanup_and_reboot(path)
        :ok

      {output, status} ->
        log("firmware upgrade failed with status #{status}. Error output: #{output}", :debug)
        schedule_source_cleanup(path)
        {:error, :upgrade_failed}
    end
  end

  defp prepare_source(binary), do: File.write!(@firmware_source_path, binary)

  defp run_upgrade(path \\ @firmware_source_path) do
    System.cmd("sh", [
      "-c",
      "fwup -i #{path} --apply --task upgrade " <>
        "--no-unmount -d #{Nerves.Runtime.KV.get("nerves_fw_devpath")}"
    ])
  end

  defp schedule_source_cleanup_and_reboot(path \\ @firmware_source_path) do
    spawn(fn ->
      :timer.sleep(1000)
      cleanup_source(path)
      Nerves.Runtime.reboot()
    end)
  end

  defp schedule_source_cleanup(path \\ @firmware_source_path),
    do: spawn(fn -> cleanup_source(path) end)

  defp cleanup_source(path), do: File.rm!(path)
end
