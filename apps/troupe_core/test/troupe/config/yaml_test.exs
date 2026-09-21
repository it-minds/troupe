defmodule Troupe.Config.YamlTest do
  use ExUnit.Case, async: true

  alias Troupe.Config.Yaml

  # The only property that matters: what is written reads back as the map that went in.
  defp round_trip(map) do
    {:ok, read} = map |> Yaml.encode() |> YamlElixir.read_from_string()
    read
  end

  test "a laptop config survives a write, env references and awkward strings included" do
    config = %{
      "provider" => "openai",
      "base_url" => "https://gw.example/v1",
      "api_key" => "{env:GW_KEY}",
      "auth" => "bearer",
      "max_branches" => 8,
      "compact_at" => 0.8,
      "auto_approve" => false,
      "fake_script" => nil,
      "notes" => "a: colon, a # hash, a \"quote\", !tag and\na newline",
      "models" => %{"default" => "gateway/claude-opus-5", "windows" => %{"some-model" => 128_000}},
      "read_roots" => ["~/src/dep", "/opt/other"],
      "providers" => %{
        "gateway" => %{
          "type" => "anthropic",
          "models" => %{"claude-opus-5" => %{"id" => "eu.anthropic.claude-opus-5", "context" => 400_000}}
        }
      }
    }

    assert round_trip(config) == config
  end

  test "lists of maps, as an mcp block has them, keep one map per item" do
    config = %{
      "servers" => [
        %{"name" => "fs", "command" => "npx", "args" => ["-y", "server"]},
        %{"name" => "git", "env" => %{"A" => "1"}}
      ]
    }

    assert round_trip(config) == config
  end

  test "keys that are not plain words are quoted" do
    config = %{"with space" => 1, "a:b" => 2, "plain_key" => 3}
    assert round_trip(config) == config
  end

  test "an empty map is an empty document, and empty collections stay empty" do
    assert round_trip(%{}) == %{}
    assert round_trip(%{"models" => %{}, "read_roots" => []}) == %{"models" => %{}, "read_roots" => []}
  end
end
