defmodule Platform.Tools.Postgres.LogicalReplicator do
  @moduledoc """
  Manages PostgreSQL logical replication publications and subscriptions.

  This module provides functions to:
  - Create publications on the writer (source) database
  - Create subscriptions on the follower (target) database
  - Enable/disable subscriptions during mode transitions
  - Check replication lag via pg_stat_subscription

  Uses PostgreSQL's native logical replication (available since PG 10).
  """

  use OriginLog

  @type repo :: module()
  @type table_name :: String.t()
  @type publication_name :: String.t()
  @type subscription_name :: String.t()
  @type connection_string :: String.t()

  @doc """
  Creates a publication on the given repo for the specified tables.

  If the publication already exists, this is a no-op.

  ## Example

      create_publication(Chat.InternalRepo, ["users"], "internal_to_main")
  """
  @spec create_publication(repo(), [table_name()], publication_name()) ::
          :ok | {:error, term()}
  def create_publication(repo, tables, publication_name) do
    tables_list = Enum.join(tables, ", ")

    sql = """
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{publication_name}') THEN
        CREATE PUBLICATION #{publication_name} FOR TABLE #{tables_list};
      END IF;
    END $$;
    """

    case repo.query(sql) do
      {:ok, _} ->
        log("created publication name=#{publication_name} tables=#{inspect(tables)}", :info)
        :ok

      {:error, reason} = error ->
        log("failed to create publication name=#{publication_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  @doc """
  Creates a subscription on the given repo to subscribe to a publication.

  The subscription will connect to the source database using the provided
  connection string and subscribe to the specified publication.

  Options:
  - `:copy_data` - whether to copy existing data (default: false, since bootstrap already copied)
  - `:enabled` - whether to enable the subscription immediately (default: true)

  ## Example

      create_subscription(
        Chat.MainRepo,
        "host=localhost port=5433 dbname=chat_internal user=replicator password=secret",
        "internal_to_main",
        "main_from_internal"
      )
  """
  @spec create_subscription(
          repo(),
          connection_string(),
          publication_name(),
          subscription_name(),
          keyword()
        ) :: :ok | {:error, term()}
  def create_subscription(
        repo,
        connection_string,
        publication_name,
        subscription_name,
        opts \\ []
      ) do
    copy_data = Keyword.get(opts, :copy_data, false)
    enabled = Keyword.get(opts, :enabled, true)

    exists_sql = """
    SELECT 1 FROM pg_subscription WHERE subname = '#{subscription_name}' LIMIT 1
    """

    case repo.query(exists_sql) do
      {:ok, %{rows: [_ | _]}} ->
        :ok

      {:ok, %{rows: []}} ->
        # First try to create with slot - if slot exists, create without and set slot after
        create_sql = """
        CREATE SUBSCRIPTION #{subscription_name}
        CONNECTION '#{connection_string}'
        PUBLICATION #{publication_name}
        WITH (copy_data = #{copy_data}, enabled = #{enabled});
        """

        case repo.query(create_sql) do
          {:ok, _} ->
            log("created subscription name=#{subscription_name} publication=#{publication_name} copy_data=#{copy_data} enabled=#{enabled}", :info)
            :ok

          {:error, %{postgres: %{message: msg}} = reason} = error ->
            if String.contains?(msg || "", "already exists") do
              # Slot exists on source - create subscription without slot, then attach
              create_without_slot(repo, connection_string, publication_name, subscription_name, copy_data, enabled)
            else
              log("failed to create subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
              error
            end

          {:error, reason} = error ->
            log("failed to create subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
            error
        end

      {:error, reason} = error ->
        log("failed to check existing subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  # Create subscription without auto-creating slot, then attach to existing slot
  defp create_without_slot(repo, connection_string, publication_name, subscription_name, copy_data, enabled) do
    # Create subscription with create_slot=false
    create_sql = """
    CREATE SUBSCRIPTION #{subscription_name}
    CONNECTION '#{connection_string}'
    PUBLICATION #{publication_name}
    WITH (copy_data = #{copy_data}, enabled = false, create_slot = false);
    """

    case repo.query(create_sql) do
      {:ok, _} ->
        # Now set the slot name to use the existing slot
        set_slot_sql = "ALTER SUBSCRIPTION #{subscription_name} SET (slot_name = '#{subscription_name}')"

        case repo.query(set_slot_sql) do
          {:ok, _} ->
            # Enable if requested
            if enabled do
              enable_sql = "ALTER SUBSCRIPTION #{subscription_name} ENABLE"
              repo.query(enable_sql)
            end

            log("created subscription name=#{subscription_name} (reused existing slot)", :info)
            :ok

          {:error, reason} = error ->
            log("failed to set slot for subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
            error
        end

      {:error, reason} = error ->
        log("failed to create subscription without slot name=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  @doc """
  Enables a subscription.

  If the replication slot is missing (e.g., source DB was reinitialized),
  this will attempt to refresh the subscription to recreate the slot.

  ## Example

      enable_subscription(Chat.MainRepo, "main_from_internal")
  """
  @spec enable_subscription(repo(), subscription_name()) :: :ok | {:error, term()}
  def enable_subscription(repo, subscription_name) do
    # First, ensure the slot exists by refreshing if needed
    case ensure_slot_exists(repo, subscription_name) do
      :ok ->
        sql = "ALTER SUBSCRIPTION #{subscription_name} ENABLE"

        case repo.query(sql) do
          {:ok, _} ->
            log("enabled subscription name=#{subscription_name}", :info)
            :ok

          {:error, reason} = error ->
            log("failed to enable subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
            error
        end

      {:error, _} = error ->
        error
    end
  end

  # Ensures the replication slot exists on the source, recreating if needed
  # This is called BEFORE enabling, so we use SET (slot_name = ...) approach
  # which works on disabled subscriptions
  defp ensure_slot_exists(repo, subscription_name) do
    # Check if slot exists by querying subscription's slot name
    check_sql = """
    SELECT subslotname, subenabled FROM pg_subscription WHERE subname = '#{subscription_name}'
    """

    case repo.query(check_sql) do
      {:ok, %{rows: [[slot_name, _enabled]]}} when not is_nil(slot_name) ->
        # Subscription has a slot configured - verify it exists on source
        # by trying to drop and recreate (this works even when disabled)
        verify_or_recreate_slot(repo, subscription_name, slot_name)

      {:ok, %{rows: [[nil, _enabled]]}} ->
        # No slot configured (subscription created with create_slot=false)
        :ok

      {:ok, %{rows: []}} ->
        {:error, :subscription_not_found}

      {:error, reason} = error ->
        log("failed to check subscription slot name=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  # Verify slot exists or recreate it - works on disabled subscriptions
  defp verify_or_recreate_slot(repo, subscription_name, slot_name) do
    # The safest approach: drop slot reference and recreate
    # SET (slot_name = NONE) drops the slot on source if it exists
    # SET (slot_name = 'name') creates a new slot on source
    # This works regardless of subscription enabled state
    drop_sql = "ALTER SUBSCRIPTION #{subscription_name} SET (slot_name = NONE)"
    create_sql = "ALTER SUBSCRIPTION #{subscription_name} SET (slot_name = '#{slot_name}')"

    case repo.query(drop_sql) do
      {:ok, _} ->
        case repo.query(create_sql) do
          {:ok, _} ->
            log("verified/recreated slot=#{slot_name} for subscription=#{subscription_name}", :debug)
            :ok

          {:error, reason} = error ->
            log("failed to create slot=#{slot_name} subscription=#{subscription_name} reason=#{inspect(reason)}", :error)
            error
        end

      {:error, reason} = error ->
        log("failed to drop slot reference subscription=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  @doc """
  Disables a subscription.

  ## Example

      disable_subscription(Chat.MainRepo, "main_from_internal")
  """
  @spec disable_subscription(repo(), subscription_name()) :: :ok | {:error, term()}
  def disable_subscription(repo, subscription_name) do
    sql = "ALTER SUBSCRIPTION #{subscription_name} DISABLE"

    case repo.query(sql) do
      {:ok, _} ->
        log("disabled subscription name=#{subscription_name}", :info)
        :ok

      {:error, reason} = error ->
        log("failed to disable subscription name=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

  @doc """
  Checks replication lag for a subscription via pg_stat_subscription.

  Returns the lag in bytes, or {:error, reason} if the subscription is not found
  or an error occurs.

  ## Example

      check_replication_lag(Chat.MainRepo, "main_from_internal")
      # => {:ok, 0} (no lag)
      # => {:ok, 1024} (1KB lag)
  """
  @spec check_replication_lag(repo(), subscription_name()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def check_replication_lag(repo, subscription_name) do
    sql = """
    SELECT
      COALESCE(
        pg_wal_lsn_diff(latest_end_lsn, received_lsn),
        0
      ) AS lag_bytes
    FROM pg_stat_subscription
    WHERE subname = '#{subscription_name}'
    """

    case repo.query(sql) do
      {:ok, %{rows: [[lag_bytes]]}} when is_number(lag_bytes) ->
        {:ok, trunc(lag_bytes)}

      {:ok, %{rows: []}} ->
        {:error, :subscription_not_found}

      {:error, reason} = error ->
        log("failed to check lag subscription=#{subscription_name} reason=#{inspect(reason)}", :error)
        error
    end
  end

end
