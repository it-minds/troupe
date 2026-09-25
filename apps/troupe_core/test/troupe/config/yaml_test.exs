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

  describe "edit_list/4" do
    @file_text """
    # my settings
    models:
      default: gateway/glm-5.2   # the one I use

    # repositories I trust
    trusted_workspaces:
      - ~/src/work      # everything at work
      # the old one
      - "/opt/legacy"

    # after the list
    max_turns: 40
    """

    defp keep_all(_entry), do: true

    test "adds an item under the last one, and leaves every other line as it was" do
      assert {:ok, text} = Yaml.edit_list(@file_text, "trusted_workspaces", &keep_all/1, ["/home/me/new"])

      assert text ==
               String.replace(
                 @file_text,
                 ~s(  - "/opt/legacy"\n),
                 ~s(  - "/opt/legacy"\n  - "/home/me/new"\n)
               )
    end

    test "removes the items it is told to, keeping the comments and the other items' spelling" do
      assert {:ok, text} = Yaml.edit_list(@file_text, "trusted_workspaces", &(&1 != "/opt/legacy"), [])
      assert text == String.replace(@file_text, ~s(  - "/opt/legacy"\n), "")
      assert text =~ "  - ~/src/work      # everything at work\n"
      assert text =~ "# after the list\nmax_turns: 40\n"
    end

    test "an emptied list is written as [], with the key line's comment kept" do
      text = "trusted_workspaces:   # mine\n  - /a\nmax_turns: 3\n"

      assert {:ok, "trusted_workspaces: []   # mine\nmax_turns: 3\n"} =
               Yaml.edit_list(text, "trusted_workspaces", &(&1 != "/a"), [])
    end

    test "items at the left margin stay there" do
      text = "trusted_workspaces:\n- /a\nmax_turns: 3\n"

      assert {:ok, "trusted_workspaces:\n- /a\n- \"/b\"\nmax_turns: 3\n"} =
               Yaml.edit_list(text, "trusted_workspaces", &keep_all/1, ["/b"])
    end

    test "a file without the key gets it at the end, and a file ending without a newline gets one" do
      assert {:ok, "max_turns: 3\ntrusted_workspaces:\n  - \"/b\"\n"} =
               Yaml.edit_list("max_turns: 3", "trusted_workspaces", &keep_all/1, ["/b"])

      assert {:ok, "trusted_workspaces:\n  - \"/b\"\n"} = Yaml.edit_list("", "trusted_workspaces", &keep_all/1, ["/b"])
      assert {:ok, "max_turns: 3\n"} = Yaml.edit_list("max_turns: 3\n", "trusted_workspaces", &keep_all/1, [])
    end

    test "a list in brackets is written out one item a line; the rest of the file is untouched" do
      text = "# top\ntrusted_workspaces: [/a, \"/b\"]\n# next\nmax_turns: 3\n"

      assert {:ok, "# top\ntrusted_workspaces:\n  - \"/b\"\n  - \"/c\"\n# next\nmax_turns: 3\n"} =
               Yaml.edit_list(text, "trusted_workspaces", &(&1 != "/a"), ["/c"])
    end

    test "Windows line endings and a byte order mark stay as they were" do
      text = <<0xEF, 0xBB, 0xBF>> <> "trusted_workspaces:\r\n  - /a\r\nmax_turns: 3\r\n"

      assert {:ok, edited} = Yaml.edit_list(text, "trusted_workspaces", &keep_all/1, ["C:/src/b"])
      assert edited == <<0xEF, 0xBB, 0xBF>> <> "trusted_workspaces:\r\n  - /a\r\n  - \"C:/src/b\"\r\nmax_turns: 3\r\n"
    end

    test "a nested key of the same name is not the list" do
      text = "x-notes:\n  trusted_workspaces: [/nope]\ntrusted_workspaces:\n  - /a\n"
      assert {:ok, edited} = Yaml.edit_list(text, "trusted_workspaces", &keep_all/1, ["/b"])
      assert edited == text <> "  - \"/b\"\n"
    end

    test "refuses what it cannot change without changing more: not YAML, not a list, a shape it does not follow" do
      assert :error = Yaml.edit_list("a: [unclosed\n", "trusted_workspaces", &keep_all/1, ["/b"])
      assert :error = Yaml.edit_list("trusted_workspaces: /a\n", "trusted_workspaces", &keep_all/1, ["/b"])
      assert :error = Yaml.edit_list("{trusted_workspaces: [/a]}\n", "trusted_workspaces", &keep_all/1, ["/b"])
    end
  end
end
