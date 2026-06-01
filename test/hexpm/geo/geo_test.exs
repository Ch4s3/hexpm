defmodule Hexpm.GeoTest do
  use ExUnit.Case, async: true

  describe "flag_emoji/1" do
    test "converts a two-letter ISO code to a flag emoji" do
      assert Hexpm.Geo.flag_emoji("US") == <<0x1F1FA::utf8, 0x1F1F8::utf8>>
      assert Hexpm.Geo.flag_emoji("DE") == <<0x1F1E9::utf8, 0x1F1EA::utf8>>
    end

    test "returns empty string for anything that is not a 2-letter A-Z code" do
      assert Hexpm.Geo.flag_emoji("USA") == ""
      assert Hexpm.Geo.flag_emoji("u") == ""
      assert Hexpm.Geo.flag_emoji("us") == ""
      assert Hexpm.Geo.flag_emoji("") == ""
    end
  end

  describe "lookup_country/1" do
    test "returns nil for a nil IP without calling the implementation" do
      assert Hexpm.Geo.lookup_country(nil) == nil
    end

    test "delegates to the configured implementation (Local default returns nil)" do
      # config/test.exs sets geo_impl: Hexpm.Geo.Local
      assert Hexpm.Geo.lookup_country("8.8.8.8") == nil
    end
  end
end
