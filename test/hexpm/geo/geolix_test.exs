defmodule Hexpm.Geo.GeolixTest do
  use ExUnit.Case, async: true

  alias Hexpm.Geo.Geolix

  describe "parse_result/1" do
    test "extracts iso_code and resolved name" do
      result = %{country: %{iso_code: "US", name: "United States"}}
      assert Geolix.parse_result(result) == %{iso_code: "US", name: "United States"}
    end

    test "falls back to the english name when :name is absent" do
      result = %{country: %{iso_code: "US", names: %{en: "United States"}}}
      assert Geolix.parse_result(result) == %{iso_code: "US", name: "United States"}
    end

    test "falls back to the iso code when no name is available" do
      result = %{country: %{iso_code: "DE"}}
      assert Geolix.parse_result(result) == %{iso_code: "DE", name: "DE"}
    end

    test "returns nil when the country has no iso_code" do
      assert Geolix.parse_result(%{country: %{}}) == nil
    end

    test "returns nil for a missing/empty/nil lookup result" do
      assert Geolix.parse_result(%{}) == nil
      assert Geolix.parse_result(nil) == nil
      assert Geolix.parse_result({:error, :not_found}) == nil
    end
  end
end
