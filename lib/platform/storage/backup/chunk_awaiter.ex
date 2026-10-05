defmodule Platform.Storage.Backup.ChunkAwaiter do
  @moduledoc "Waits until the backup drive's chunk pipeline has copied every chunk present locally, or until it stalls."

  use Toolbox.OriginLog

  alias Chat.Data.File.ChunkPresence
  alias Platform.Tools.Postgres

  @stall_limit 60
  @poll_interval 1_000
  @progress_every 10

  def await(nil), do: :ok

  def await(backup_repo) do
    source_id = Postgres.system_identifier(Chat.Repo)

    count =
      ChunkPresence.backfill_missing_from_file_chunks(
        source_id,
        Chat.TimeKeeper.now_unix(),
        repo: backup_repo
      )

    if count > 0, do: log("backfilled #{count} missing_chunks on backup", :info)

    Phoenix.PubSub.broadcast(Chat.PubSub, "chunk_pipeline", {:chunk_pipeline, :pg_diff_copied})

    case ChunkPresence.present_chunk_keys(repo: Chat.Repo) do
      [] ->
        log("no chunks to copy to backup", :info)

      available ->
        total = length(available)
        log("awaiting #{total} chunks on backup drive", :info)
        poll(MapSet.new(available), backup_repo, total, total, 0)
    end
  end

  defp poll(_available_set, _backup_repo, _total, _prev, stall) when stall > @stall_limit do
    log("chunk copy to backup stalled after #{@stall_limit}s, proceeding with eject", :warning)
  end

  defp poll(available_set, backup_repo, total, prev_remaining, stall) do
    remaining =
      ChunkPresence.missing_chunk_keys(repo: backup_repo)
      |> MapSet.new()
      |> MapSet.intersection(available_set)
      |> MapSet.size()

    cond do
      remaining == 0 ->
        log("all #{total} chunks copied to backup", :info)

      remaining < prev_remaining ->
        log("awaiting #{remaining}/#{total} chunks on backup...", :info)
        Process.sleep(@poll_interval)
        poll(available_set, backup_repo, total, remaining, 0)

      true ->
        new_stall = stall + 1

        if rem(new_stall, @progress_every) == 0,
          do: log("awaiting #{remaining}/#{total} chunks on backup...", :info)

        Process.sleep(@poll_interval)
        poll(available_set, backup_repo, total, remaining, new_stall)
    end
  end
end
