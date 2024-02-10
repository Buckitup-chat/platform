defmodule Platform.ChatBridge.NervesKeyWorker do
  @moduledoc "Worker for Nerves Key"
  require Logger
  use GenServer
  import Tools.GenServerHelpers

  @topic Application.compile_env!(:chat, :topic_to_nerveskey)
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @impl true
  def init(_) do
    {:ok, %{}, {:continue, :init}}
  end

  @impl true
  def handle_continue(:init, state) do
    Phoenix.PubSub.subscribe(Chat.PubSub, @topic)
    noreply(state)
  end

  @impl true
  def handle_info({command, pid}, state) do
    case command do
      :status -> {:status, device_status()}
      {:generate_cert, years} -> {:cert, generate_certificates(years)}
      {:provision, hash, name} -> {:provisioned, provision(hash, name)}
    end
    |> then(&send(pid, &1))

    noreply(state)
  rescue
    _ -> noreply(state)
  end

  def device_status do
    transport = find_transport()

    cond do
      !transport ->
        :no_chip

      !NervesKey.detected?(transport) ->
        :no_chip

      !NervesKey.provisioned?(transport) ->
        {:not_provisioned, transport |> NervesKey.default_info() |> Map.from_struct()}

      true ->
        {:provisioned, NervesKey.default_info(transport) |> Map.from_struct()}
    end
  end

  def generate_certificates(years) do
    NervesKey.create_signing_key_pair(years_valid: years)
    |> tap(&Process.put(:cert_and_key, &1))
  end

  def hash_cert_and_key(cert, key) do
    pem_cert = X509.Certificate.to_pem(cert)
    pem_key = X509.PrivateKey.to_pem(key)

    Enigma.hash(pem_cert <> pem_key)
  end

  def provision(hash, name) do
    with {cert, key} <- Process.get(:cert_and_key),
         my_hash <- hash_cert_and_key(cert, key),
         true <- hash == my_hash,
         transport <- find_transport(),
         manufacturer_sn <- NervesKey.default_info(transport).manufacturer_sn,
         false <- NervesKey.provisioned?(transport) do
      #      NervesKey.provision(cert, name)
      provision_info = %NervesKey.ProvisioningInfo{
        manufacturer_sn: manufacturer_sn,
        board_name: name
      }

      # Double-check what you typed above before running this
      # NervesKey.provision(transport, provision_info, cert, key)
      :skip
    else
      _ -> :error
    end
  end

  defp find_transport do
    Platform.NervesKey.Transport
    |> Agent.get(fn state -> state end)
  end

  defp stubs do
    {:status, {:not_provisioned, %{board_name: "NervesKey", manufacturer_sn: "AER5WYW6655PL3Q"}}}
    {:status, :no_chip}

    {:cert,
     {{:OTPCertificate,
       {:OTPTBSCertificate, :v3, 90_464_619_148_716_124_763_884_972_867_473_477_133,
        {:SignatureAlgorithm, {1, 2, 840, 10045, 4, 3, 2}, :asn1_NOVALUE},
        {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "Signer"}}]]},
        {:Validity, {:utcTime, ~c"240207190000Z"}, {:generalTime, ~c"21240207190000Z"}},
        {:rdnSequence, [[{:AttributeTypeAndValue, {2, 5, 4, 3}, {:utf8String, "Signer"}}]]},
        {:OTPSubjectPublicKeyInfo,
         {:PublicKeyAlgorithm, {1, 2, 840, 10045, 2, 1},
          {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}}},
         {:ECPoint,
          <<4, 181, 165, 125, 90, 53, 200, 74, 57, 84, 145, 186, 104, 173, 98, 145, 33, 15, 43,
            145, 107, 35, 152, 223, 185, 252, 40, 55, 176, 83, 49, 254, 178, 213, 71, 233, 229,
            185, 188, 178, 197, 196, 61, 124, 115, 12, 30, 133, 185, 91, 64, 67, 145, 181, 70,
            184, 242, 64, 238, 161, 214, 181, 206, 75, 194>>}}, :asn1_NOVALUE, :asn1_NOVALUE,
        [
          {:Extension, {2, 5, 29, 19}, true, {:BasicConstraints, true, 0}},
          {:Extension, {2, 5, 29, 15}, true, [:digitalSignature, :keyCertSign, :cRLSign]},
          {:Extension, {2, 5, 29, 37}, false,
           [{1, 3, 6, 1, 5, 5, 7, 3, 1}, {1, 3, 6, 1, 5, 5, 7, 3, 2}]},
          {:Extension, {2, 5, 29, 14}, false,
           <<40, 191, 205, 13, 116, 175, 247, 99, 181, 189, 187, 188, 234, 63, 208, 46, 199, 113,
             0, 65>>},
          {:Extension, {2, 5, 29, 35}, false,
           {:AuthorityKeyIdentifier,
            <<40, 191, 205, 13, 116, 175, 247, 99, 181, 189, 187, 188, 234, 63, 208, 46, 199, 113,
              0, 65>>, :asn1_NOVALUE, :asn1_NOVALUE}}
        ]}, {:SignatureAlgorithm, {1, 2, 840, 10045, 4, 3, 2}, :asn1_NOVALUE},
       <<48, 69, 2, 33, 0, 153, 65, 150, 113, 253, 165, 166, 128, 161, 111, 13, 101, 147, 98, 62,
         20, 7, 55, 124, 246, 50, 45, 72, 188, 194, 56, 105, 144, 32, 81, 249, 150, 2, 32, 6, 64,
         130, 220, 85, 159, 85, 191, 53, 207, 76, 234, 20, 225, 36, 190, 215, 91, 207, 203, 110,
         176, 207, 77, 83, 20, 11, 60, 112, 237, 37, 133>>},
      {:ECPrivateKey, 1,
       <<144, 96, 252, 179, 145, 62, 44, 76, 202, 23, 53, 171, 42, 183, 119, 46, 186, 136, 22, 99,
         109, 234, 63, 230, 197, 75, 39, 251, 147, 233, 57, 234>>,
       {:namedCurve, {1, 2, 840, 10045, 3, 1, 7}},
       <<4, 181, 165, 125, 90, 53, 200, 74, 57, 84, 145, 186, 104, 173, 98, 145, 33, 15, 43, 145,
         107, 35, 152, 223, 185, 252, 40, 55, 176, 83, 49, 254, 178, 213, 71, 233, 229, 185, 188,
         178, 197, 196, 61, 124, 115, 12, 30, 133, 185, 91, 64, 67, 145, 181, 70, 184, 242, 64,
         238, 161, 214, 181, 206, 75, 194>>, :asn1_NOVALUE}}}
  end
end
