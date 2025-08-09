defmodule Platform.Internal.PgDb do
  @moduledoc """
  Supervisor for PostgreSQL database processes.
  Handles initialization, startup, and monitoring of PostgreSQL server.
  """

  use Supervisor
  require Logger

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Logger.info("Starting PostgreSQL database supervisor")

    # Initialize PostgreSQL database at supervisor startup
    # This ensures it's ready before any children try to use it
    case Platform.PgDb.initialize() do
      :ok ->
        Logger.info("PostgreSQL database initialized successfully")
      {:error, reason} ->
        Logger.error("PostgreSQL database initialization failed: #{inspect(reason)}")
    end

    children = [
      # Use the child_spec from Platform.PgDb to start and monitor the PostgreSQL server
      Platform.PgDb.child_spec()
    ]

    # Use :one_for_one strategy - if PostgreSQL fails, only restart it
    result = Supervisor.init(children, strategy: :one_for_one)

    # After initializing supervisor, set up the Chat.Repo database
    Task.start(fn ->
      # Give PostgreSQL a moment to start up fully
      Process.sleep(2000)
      setup_chat_database()
    end)

    result
  end

  @doc """
  Stop the PostgreSQL server gracefully.
  """
  def stop_server do
    Platform.PgDb.stop()
  end

  @doc """
  Check if the PostgreSQL server is running.
  """
  def server_running? do
    Platform.PgDb.server_running?()
  end

  @doc """
  Run a SQL command against the PostgreSQL database.
  """
  def run_sql(sql, db_name \\ "postgres") do
    Platform.PgDb.run_sql(sql, db_name)
  end

  @doc """
  Create a new PostgreSQL database.
  """
  def create_database(db_name) do
    Platform.PgDb.create_database(db_name)
  end

  # Private functions

  @doc false
  defp setup_chat_database do
    if Platform.PgDb.server_running?() do
      Logger.info("Setting up database for Chat.Repo")

      # Create the chat database if it doesn't exist
      case Platform.PgDb.run_sql("SELECT 1 FROM pg_database WHERE datname = 'chat'") do
        {:ok, output} ->
          if String.contains?(output, "0 rows") do
            Logger.info("Creating 'chat' database")
            case Platform.PgDb.create_database("chat") do
              {:ok, _} -> Logger.info("'chat' database created successfully")
              {:error, reason} -> Logger.error("Failed to create 'chat' database: #{reason}")
            end
          else
            Logger.info("'chat' database already exists")
          end

          # # Run migrations if modules are available
          # try do
          #   if Code.ensure_loaded?(Chat.Repo) && Code.ensure_loaded?(Ecto.Migrator) do
          #     Logger.info("Running migrations for Chat database")

          #     # Get the migrations path
          #     migrations_path = Path.join([:code.priv_dir(:chat), "repo", "migrations"])

          #     if File.exists?(migrations_path) do

          #       # Run migrations
          #       Ecto.Migrator.run(Chat.Repo, migrations_path, :up, all: true)
          #       Logger.info("Migrations completed successfully")

          #     else
          #       Logger.warning("No migrations directory found at #{migrations_path}")
          #     end
          #   else
          #     modules = []
          #     modules = if !Code.ensure_loaded?(Chat.Repo), do: ["Chat.Repo" | modules], else: modules
          #     modules = if !Code.ensure_loaded?(Ecto.Migrator), do: ["Ecto.Migrator" | modules], else: modules
          #     Logger.info("Skipping migrations, required modules not available: #{Enum.join(modules, ", ")}")
          #   end
          # rescue
          #   e -> Logger.error("Error running migrations: #{inspect(e)}")
          # end

        {:error, reason} ->
          Logger.error("Error checking for 'chat' database: #{reason}")
      end

      # # Set environment variables for PostgreSQL connection
      # # This ensures Chat.Repo will find the correct socket directory when it starts
      # try do
      #   pg_port = Application.get_env(:chat, :pg_port, 5432)
      #   pg_socket_dir = Application.get_env(:chat, :pg_socket_dir, "/root/pg/run")

      #   # Set environment variables that will be used by Chat.Repo's configuration
      #   System.put_env("PGPORT", to_string(pg_port))
      #   System.put_env("PGSOCKET_DIR", pg_socket_dir)

      #   Logger.info("PostgreSQL environment configured: socket_dir=#{pg_socket_dir}, port=#{pg_port}")
      #   Logger.info("Chat.Repo will be started by the Chat application's supervision tree")
      # rescue
      #   e -> Logger.error("Unexpected error during PostgreSQL environment setup: #{inspect(e)}")
      # end
    else
      Logger.error("PostgreSQL server not running, can't set up database for Chat.Repo")
    end
  end
end
