defmodule Platform.Tools.Postgres.SharedMemoryTest do
  use ExUnit.Case, async: true

  import Rewire

  @moduletag :capture_log

  @pg_data_dir "/nonexistent/pg/data"

  # Stubs precede the rewires that consume them: `rewire/2` resolves them at compile time.

  defmodule OnlyIpcToolsExist do
    @moduledoc """
    Reports the IPC binaries as the only paths that exist.

    Two effects, both required: a missing /dev/shm keeps POSIX cleanup away from the
    developer's real one, where it would delete a locally running PostgreSQL's segments,
    and a missing postmaster.pid makes every listed segment count as stale.
    """

    def dir?(_path), do: false
    def exists?("/usr/bin/" <> _tool), do: true
    def exists?(_path), do: false
  end

  defmodule TimingOutIpc do
    def cmd(_command, _args, _opts), do: {"", :timeout}
  end

  defmodule WorkingIpc do
    @ipcs_output """
    ------ Shared Memory Segments --------
    key        shmid      owner      perms      bytes      nattch     status
    0x0052e2c1 32769      postgres   600        56         0
    """

    def cmd("/usr/bin/ipcs", _args, _opts), do: {@ipcs_output, 0}

    def cmd("/usr/bin/ipcrm", ["-m", shmid], _opts) do
      send(self(), {:ipcrm, shmid})
      {"", 0}
    end
  end

  rewire(Platform.Tools.Postgres.SharedMemory,
    MuonTrap: TimingOutIpc,
    File: OnlyIpcToolsExist,
    as: WithTimingOutIpc
  )

  rewire(Platform.Tools.Postgres.SharedMemory,
    MuonTrap: WorkingIpc,
    File: OnlyIpcToolsExist,
    as: WithWorkingIpc
  )

  describe "cleanup_stale/1 with System V segments" do
    test "degrades to a log when ipcs never returns" do
      assert :ok = WithTimingOutIpc.cleanup_stale(@pg_data_dir)
    end

    test "removes segments left by a postgres that is no longer running" do
      assert :ok = WithWorkingIpc.cleanup_stale(@pg_data_dir)

      assert_segment_removed("32769")
    end
  end

  defp assert_segment_removed(shmid), do: assert_received({:ipcrm, ^shmid})
end
