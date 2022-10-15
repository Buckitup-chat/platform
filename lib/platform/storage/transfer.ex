defmodule Platform.Storage.Transfer do
  @moduledoc "Handling data fransfers bnetween dbs"

  @spec one_way(from :: pid(), to :: pid()) :: :ok
  def one_way(from, to) do
    copy_data_one_way(from, to)
  end

  @spec both_ways(from :: pid(), to :: pid()) :: :ok
  def both_ways(from, to) do
    from_keyset = read_keyset(from)
    to_keyset = read_keyset(to)

    fresh_keys_to =
      from_keyset
      |> MapSet.difference(to_keyset)

    fresh_keys_from =
      to_keyset
      |> MapSet.difference(from_keyset)

    transfer(fresh_keys_to, from, to)
    transfer(fresh_keys_from, to, from)
  end

  defp copy_data_one_way(from, to) do
    from_keyset = read_keyset(from)
    to_keyset = read_keyset(to)

    from_keyset
    |> MapSet.difference(to_keyset)
    |> transfer(from, to)
  end

  defp read_keyset(db) do
    CubDB.select(db)
    |> Stream.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp transfer(keys, from, to) do
    keys
    |> Enum.each(&transfer_piece(&1, from, to))
  end

  defp transfer_piece(key, from, to) do
    case CubDB.get(from, key, :not_found_in_source_db) do
      :not_found_in_source_db -> :ignore
      value -> CubDB.put(to, key, value)
    end
  end
end
