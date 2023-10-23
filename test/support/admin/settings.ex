defmodule Support.Admin.Settings do
  @moduledoc false

  alias Chat.AdminRoom

  def media_settings_set_to(main: main_if_absent?, scenario: scenario) do
    AdminRoom.get_media_settings()
    |> Map.put(:main, main_if_absent?)
    |> Map.put(:functionality, scenario)
    |> AdminRoom.store_media_settings()
  end
end
