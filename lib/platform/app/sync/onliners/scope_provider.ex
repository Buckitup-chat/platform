defmodule Platform.App.Sync.Onliners.ScopeProvider do
  @moduledoc "Gets scope for online sync"

  use GracefulGenServer, name: __MODULE__

  alias Chat.Db.Scope.KeyScope

  alias Phoenix.PubSub

  @incoming_topic "chat_onliners->platform_onliners"
  @outgoing_topic "platform_onliners->chat_onliners"

  @impl true
  def on_init(opts) do
    next = Keyword.fetch!(opts, :next)

    PubSub.subscribe(Chat.PubSub, @incoming_topic)
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, "get_online_users_keys")
    Process.send_after(self(), :restart_unless_populated, :timer.seconds(15))

    %{
      db: Keyword.fetch!(opts, :target),
      run_under: Keyword.fetch!(next, :under),
      run_spec: Keyword.fetch!(next, :run),
      user_keys: nil,
      db_keys: nil
    }
  end

  @impl true
  def handle_call(:db_keys, _from, state) do
    {:reply, state.db_keys, state}
  end

  @impl true
  def on_msg({:user_keys, user_keys}, %{db: target_db} = state) do
    Process.send_after(self(), :start_next_stage, 10)

    backup_keys = KeyScope.get_keys(Chat.Db.db(), user_keys)
    restoration_keys = KeyScope.get_keys(target_db, user_keys)

    {:noreply, %{state | user_keys: user_keys, db_keys: {backup_keys, restoration_keys}}}
  end

  def on_msg(:start_next_stage, %{run_spec: spec, run_under: supervisor} = state) do
    Platform.start_next_stage(supervisor, spec)

    {:noreply, state}
  end

  def on_msg(:restart_unless_populated, %{db_keys: keys} = state) do
    if is_nil(keys) do
      Process.exit(self(), :normal)
    end

    {:noreply, state}
  end

  @impl true
  def on_exit(_reason, _state) do
    PubSub.unsubscribe(Chat.PubSub, @incoming_topic)
  end
end
