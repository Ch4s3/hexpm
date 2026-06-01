defmodule Hexpm.Geo.Local do
  @moduledoc "No-op geo implementation used in dev and test; never resolves a country."
  @behaviour Hexpm.Geo

  @impl Hexpm.Geo
  def lookup_country(_ip), do: nil
end
