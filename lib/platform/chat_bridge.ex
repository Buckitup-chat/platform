defmodule Platform.ChatBridge do
  @moduledoc "Public face for the platform→chat PubSub bridge"

  alias Phoenix.PubSub

  @outgoing_topic Application.compile_env!(:chat, :topic_from_platform)

  @doc """
  Pushes a message to Chat.

  `Platform.ChatBridge.Worker` uses this to answer what Chat asked; boot stages
  that fail have no one waiting on them, so they report on their own.
  """
  def notify(message) do
    PubSub.broadcast(Chat.PubSub, @outgoing_topic, {:platform_response, message})
  rescue
    # Chat's PubSub may not be up yet when a failing boot stage reports here -
    # don't let that mask the original failure with a crash of its own.
    _ -> :error
  end
end
