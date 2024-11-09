defmodule Platform.Dns.Server do
  @moduledoc "DnsServer to inject our domain"

  use GenServer

  require Logger

  @doc """
  Start DNS.Server` server.

  ## Options

  * `:port` - set the port number for the server
  """
  def start_link(port) do
    GenServer.start_link(__MODULE__, [port])
  end

  def init([port]) do
    socket = Socket.UDP.open!(port, as: :binary, mode: :active)
    IO.puts("Server listening at #{port}")

    # accept_loop(socket, handler)
    {:ok, %{port: port, socket: socket}}
  end

  def handle_info({:udp, client, ip, wtv, data}, state) do
    Task.start(fn ->
      proxy_dns_request(client, ip, wtv, data, state.socket)
    end)

    {:noreply, state}
  end

  defp proxy_dns_request(client, ip, wtv, data, socket) do
    data
    |> DNS.Record.decode()
    |> inject_known_or_proxy_request(client)
    |> DNS.Record.encode()
    |> then(&Socket.Datagram.send(socket, &1, {ip, wtv}))
    |> case do
      :ok -> :ok
      {:error, send_error} -> log_send_error(send_error, data)
    end
  rescue
    err -> log_error(err, data)
  end

  @domain Application.compile_env(:chat, :domain) |> to_charlist()

  defp inject_known_or_proxy_request(record, _) do
    query = hd(record.qdlist)

    case query do
      %{type: :a, domain: @domain} ->
        [
          %DNS.Resource{
            domain: query.domain,
            class: query.class,
            type: query.type,
            ttl: 10,
            data: {192, 168, 25, 1}
          }
        ]

      %{type: :cname, domain: @domain} ->
        [
          %DNS.Resource{
            domain: query.domain,
            class: query.class,
            type: query.type,
            ttl: 10,
            data: {192, 168, 25, 1}
          }
        ]

      _ ->
        {:ok, %{anlist: anlist}} =
          DNS.query(query.domain, query.type,
            nameservers: [{"8.8.4.4", 53}],
            timeout: :timer.seconds(3)
          )

        anlist
    end
    |> then(fn anlist -> %{record | anlist: anlist, header: %{record.header | qr: true}} end)
  rescue
    _ -> record
  end

  defp format_data(data) do
    data
    |> to_charlist()
    |> Enum.reduce({[], []}, fn num, {skip, str} ->
      cond do
        num < 0x20 and match?([_ | _], str) -> {[num | [Enum.reverse(str) | skip]], []}
        num < 0x20 -> {[num | skip], []}
        num -> {skip, [num | str]}
      end
    end)
    |> then(fn
      {x, []} -> x
      {x, s} -> [Enum.reverse(s) | x]
    end)
    |> Enum.reverse()
  rescue
    _ -> data
  end

  defp log_send_error(send_error, data) do
    Logger.warning([
      "[Dns.Server] sending response error: ",
      inspect(send_error),
      " on: ",
      data |> format_data() |> inspect()
    ])
  end

  defp log_error(err, data) do
    Logger.warning([
      "[Dns.Server] error: ",
      inspect(err),
      " on: ",
      data |> format_data() |> inspect()
    ])
  end
end
