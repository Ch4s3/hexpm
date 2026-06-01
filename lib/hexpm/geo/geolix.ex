defmodule Hexpm.Geo.Geolix do
  @moduledoc """
  Resolves IPs to a country using a MaxMind GeoLite2-Country database via the
  `:geolix` library. The database is configured under `config :geolix` with the
  id `:country` (see `config/runtime.exs`).
  """
  @behaviour Hexpm.Geo

  @impl Hexpm.Geo
  def lookup_country(ip) when is_binary(ip) do
    ip
    |> Geolix.lookup(where: :country)
    |> parse_result()
  end

  @doc false
  def parse_result(%{country: country}) when is_map(country) do
    case Map.get(country, :iso_code) do
      iso when is_binary(iso) -> %{iso_code: iso, name: country_name(country, iso)}
      _ -> nil
    end
  end

  def parse_result(_), do: nil

  defp country_name(country, iso) do
    Map.get(country, :name) ||
      get_in(Map.get(country, :names) || %{}, ["en"]) ||
      iso
  end
end
