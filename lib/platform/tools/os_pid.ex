defmodule Platform.Tools.OsPid do
  @moduledoc """
  Utilities for working with operating system process IDs.
  """

  @doc """
  Checks if a process with the given OS PID is alive.

  Uses the `/bin/kill -0` signal to check process existence without
  actually sending a termination signal.

  ## Parameters
    - os_pid: Integer representing the operating system process ID

  ## Returns
    - `true` if the process exists
    - `false` if the process does not exist or cannot be accessed

  ## Examples

      iex> Platform.Tools.OsPid.alive?(1)
      true

      iex> Platform.Tools.OsPid.alive?(999999)
      false
  """
  @spec alive?(integer()) :: boolean()
  def alive?(os_pid) when is_integer(os_pid) and os_pid > 0 do
    try do
      case MuonTrap.cmd("/bin/kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true) do
        {_, 0} -> true
        _ -> false
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  def alive?(_os_pid), do: false

  @doc """
  Sends a signal to a process with the given OS PID.

  ## Parameters
    - os_pid: Integer representing the operating system process ID
    - signal: Signal to send (default: 9 for SIGKILL). Can be integer or string like "TERM", "KILL", "9"

  ## Returns
    - `:ok` if the signal was sent successfully
    - `{:error, reason}` if the signal could not be sent

  ## Examples

      iex> Platform.Tools.OsPid.kill(12345)
      :ok

      iex> Platform.Tools.OsPid.kill(12345, "TERM")
      :ok

      iex> Platform.Tools.OsPid.kill(12345, 15)
      :ok
  """
  @spec kill(integer(), integer() | String.t()) :: :ok | {:error, term()}
  def kill(os_pid, signal \\ 9) when is_integer(os_pid) and os_pid > 0 do
    signal_str = signal_to_string(signal)

    try do
      case System.cmd("kill", ["-#{signal_str}", Integer.to_string(os_pid)],
             stderr_to_stdout: true
           ) do
        {_, 0} -> :ok
        {output, _} -> {:error, output}
      end
    rescue
      e -> {:error, e}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp signal_to_string(signal) when is_integer(signal), do: Integer.to_string(signal)
  defp signal_to_string(signal) when is_binary(signal), do: signal
end
