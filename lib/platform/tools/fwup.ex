defmodule Platform.Tools.Fwup do
  @moduledoc "fwup tasks"

  require Logger

  @firmware_source_path "/data/platform.fw"

  def upgrade(binary) do
    prepare_source(binary)

    case run_upgrade() do
      {_, 0} ->
        Logger.debug("[Platform.Tools.Fwup] firmware upgrade succeeded.")

        schedule_source_cleanup_and_reboot()
        :ok

      {output, status} ->
        Logger.debug(
          "[Platform.Tools.Fwup] firmware upgrade failed with status #{status}. Error output: #{output}."
        )

        schedule_source_cleanup()
        :error
    end
  end

  defp prepare_source(binary), do: File.write!(@firmware_source_path, binary)

  defp run_upgrade do
    System.cmd("sh", [
      "-c",
      "fwup -i #{@firmware_source_path} --apply --task upgrade " <>
        "--no-unmount -d #{Nerves.Runtime.KV.get("nerves_fw_devpath")}"
    ])
  end

  defp schedule_source_cleanup_and_reboot do
    spawn(fn ->
      :timer.sleep(1000)
      cleanup_source()
      Nerves.Runtime.reboot()
    end)
  end

  defp schedule_source_cleanup, do: spawn(fn -> cleanup_source() end)

  defp cleanup_source, do: File.rm!(@firmware_source_path)
end
