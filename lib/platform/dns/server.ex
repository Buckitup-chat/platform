defmodule Platform.Dns.Server do
  @moduledoc "DnsServer to inject our domain"

  use DNS.Server
  @behaviour DNS.Server

  def handle(record, _) do
    query = hd(record.qdlist)

    if match?(%{type: :a, domain: ~c"buckitup.app"}, query) do
      [
        %DNS.Resource{
          domain: query.domain,
          class: query.class,
          type: query.type,
          ttl: 10,
          data: {192, 168, 25, 1}
        }
      ]
    else
      {:ok, %{anlist: anlist}} = DNS.query(query.domain, query.type, nameservers: [{"8.8.4.4", 53}])
      anlist
    end
    |> then(fn anlist -> %{record | anlist: anlist, header: %{record.header | qr: true}} end)
  rescue
    _ -> record
  end
end
