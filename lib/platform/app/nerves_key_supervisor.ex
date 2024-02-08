defmodule Platform.App.NervesKeySupervisor do
  @moduledoc "Nerves Key supervisor"
  use Supervisor

  def start_link(_arg) do
    Supervisor.start_link(__MODULE__, name: __MODULE__)
  end

  def init(_arg) do
    [
      agent_spec(),
      Platform.ChatBridge.NervesKeyWorker
    ]
    |> Supervisor.init(strategy: :one_for_one)
  end

  defp agent_spec do
    %{
      id: Platform.NervesKey.Agent,
      start:
        {Agent, :start_link,
         [
           fn ->
             ATECC508A.Transport.I2C.init([])
             |> case do
               {:ok, i2c} -> i2c
               _ -> false
             end
           end,
           [name: Platform.NervesKey.Agent]
         ]}
    }
  end
end
