defmodule Platform.Dns do
  @moduledoc """
  Dns server to propagate buckitup.net
  """
  @behaviour DNS.Server
  use DNS.Server

  @domain 'chat.buckitup.net'
  @ip {192, 168, 24, 1}

  def handle(record, _cl) do
    query = hd(record.qdlist)

    result =
      case query.type do
        :a ->
          case query.domain do
            @domain -> @ip
            _ -> {0, 0, 0, 0}
          end

        :cname ->
          @domain

        # :txt ->
        # ['your txt value']

        _ ->
          nil
      end

    resource = %DNS.Resource{
      domain: query.domain,
      class: query.class,
      type: query.type,
      ttl: 5,
      data: result
    }

    %{record | anlist: [resource], header: %{record.header | qr: true}}
  end
end
