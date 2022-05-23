defmodule Platform.Sync.MainToInitial do
  @moduledoc ""

  use GenServer

  alias Chat.Db
  alias Platform.Leds

  @interval 5 * 60 * 1000

  def sync do
    if main_initialted?() do
      start_initial_db()
      |> sync_main_to_initial()
      |> stop_initial_db()
    end
  end

  def schedule do
    Process.send_after(self(), :tick, @interval)
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    schedule()

    {:ok, true}
  end

  @impl true
  def handle_info(:tick, true) do
    sync()
    schedule()

    {:noreply, true}
  rescue
    _ -> {:noreply, false}
  end

  def handle_info(_, state), do: {:noreply, state}

  ### Logic

  defp main_initialted? do
    CubDB.data_dir(Db.db()) != initial_db_path()
  end

  defp initial_db_path do
    Db.file_path()
  end

  defp start_initial_db do
    {:ok, pid} = CubDB.start_link(initial_db_path())

    pid
  end

  defp sync_main_to_initial(initial_pid) do
    Leds.blink_dump()
    Db.copy_data(Db.db(), initial_pid)
    Leds.blink_done()

    initial_pid
  end

  defp stop_initial_db(initial_pid) do
    CubDB.stop(initial_pid)
  end
end
