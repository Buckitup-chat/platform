defprotocol Platform.Tools.Proto.Device do
  @spec path(t()) :: String.t()
  def path(device)

  @spec name(t()) :: String.t()
  def name(device)
end

defimpl Platform.Tools.Proto.Device, for: BitString do
  def path(raw) do
    case raw do
      "/dev/" <> _ -> raw
      _ -> "/dev/" <> raw
    end
  end

  def name(raw) do
    case raw do
      "/dev/" <> name -> name
      _ -> raw
    end
  end
end
