defmodule Platform.Tools.OsPid do
  @moduledoc """
  Utilities for working with operating system process IDs.
  """

  # Callers treat a timeout as "not alive" rather than blocking on a wedged signal.
  @signal_timeout :timer.seconds(5)

  @doc """
  Checks if a process with the given OS PID is alive.

  Probes with `/bin/kill -0`, which tests existence without terminating
  anything. Everything but a clean exit reads as `false` — no such process,
  no permission, a bad PID, or a wedged `kill` hitting `@signal_timeout`.

  ## Examples

      OsPid.alive?(1)        #=> true
      OsPid.alive?(999_999)  #=> false
  """
  @spec alive?(term()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    case MuonTrap.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)],
           stderr_to_stdout: true,
           timeout: @signal_timeout
         ) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def alive?(_os_pid), do: false

  @doc """
  Sends a signal to a process with the given OS PID.

  The signal is a number or a name — `9` (default, SIGKILL), `15`, `"TERM"`,
  `"KILL"`. Returns `:ok` when `kill` exits cleanly, `{:error, reason}` with
  the command output or the raised error otherwise.

  ## Examples

      OsPid.kill(12345)          #=> :ok
      OsPid.kill(12345, "TERM")  #=> :ok
  """
  @spec kill(integer(), integer() | String.t()) :: :ok | {:error, term()}
  def kill(os_pid, signal \\ 9)
      when is_integer(os_pid) and os_pid > 0 and (is_integer(signal) or is_binary(signal)) do
    case System.cmd("kill", ["-#{signal}", Integer.to_string(os_pid)], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, output}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end
end
