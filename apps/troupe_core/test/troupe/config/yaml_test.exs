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

  describe "put/3" do
    @settings """
    # my settings, by hand
    provider: openai                  # the gateway speaks OpenAI
    base_url: https://gw.example/v1
    api_key: "{env:GW_KEY}"

    models:
      # what I use most days
      default: gateway/glm-5.2   # the one I use
      cheap: gateway/qwen

    # budgets
    max_turns: 40
    """

    defp read(text) do
      {:ok, map} = YamlElixir.read_from_string(text)
      map
    end

    test "one key written is one line changed, its comment kept" do
      assert {:ok, text} = Yaml.put(@settings, ["max_turns"], 65)
      assert text == String.replace(@settings, "max_turns: 40", "max_turns: 65")

      assert {:ok, text} = Yaml.put(@settings, ["provider"], "anthropic")
      assert text == String.replace(@settings, "provider: openai ", "provider: anthropic ")
    end

    test "a nested key is found under its parent, and only its line changes" do
      assert {:ok, text} = Yaml.put(@settings, ["models", "default"], "gateway/opus")
      assert text == String.replace(@settings, "default: gateway/glm-5.2 ", "default: gateway/opus ")
    end

    test "a missing key is added after the last key of its map, and those are the only lines added" do
      assert {:ok, text} = Yaml.put(@settings, ["models", "expensive"], "gateway/opus")

      assert text ==
               String.replace(@settings, "  cheap: gateway/qwen\n", "  cheap: gateway/qwen\n  expensive: gateway/opus\n")

      assert {:ok, text} = Yaml.put(@settings, ["max_depth"], 3)
      assert text == @settings <> "max_depth: 3\n"
    end

    test "a missing parent is added with the key beneath it" do
      assert {:ok, text} = Yaml.put(@settings, ["limits", "max_turns"], 80)
      assert text == @settings <> "limits:\n  max_turns: 80\n"
      assert read(text)["limits"] == %{"max_turns" => 80}

      assert {:ok, "# nothing yet\nmodels:\n  default: m\n"} = Yaml.put("# nothing yet\n", ["models", "default"], "m")
      assert {:ok, "models:\n  default: m\n"} = Yaml.put("", ["models", "default"], "m")
    end

    test "a value is quoted when YAML needs it to read back as the string it is" do
      for value <- ["{env:MODEL}", "yes", "off", "123", "0.5", "null", "~", "a # b", "a: b", "", "- x", "trailing:", "it's"] do
        assert {:ok, text} = Yaml.put(@settings, ["models", "default"], value)
        assert read(text)["models"]["default"] == value, inspect(value)
        assert text =~ ~s(  default: #{Jason.encode!(value)}   # the one I use\n), inspect(value)
      end

      # A value that reads back as itself goes bare, and one quoted before stays quoted.
      assert {:ok, text} = Yaml.put(@settings, ["base_url"], "https://other.example/v1")
      assert text =~ "\nbase_url: https://other.example/v1\n"

      assert {:ok, text} = Yaml.put(@settings, ["api_key"], "{env:OTHER}")
      assert text =~ ~s(\napi_key: "{env:OTHER}"\n)
      assert {:ok, text} = Yaml.put(@settings, ["api_key"], "plain")
      assert text =~ ~s(\napi_key: "plain"\n)
    end

    test "a key with no value, or only a comment, gets one" do
      assert {:ok, "fake_script: /tmp/s.json   # later\nmax_turns: 3\n"} =
               Yaml.put("fake_script:   # later\nmax_turns: 3\n", ["fake_script"], "/tmp/s.json")

      assert {:ok, "fake_script: x\n"} = Yaml.put("fake_script:\n", ["fake_script"], "x")
    end

    test "a map written in braces is written out one key a line; the rest of the file is untouched" do
      text = "# top\nmodels: {default: a, cheap: b}   # both\nmax_turns: 3\n"

      assert {:ok, "# top\nmodels:   # both\n  cheap: c\n  default: a\nmax_turns: 3\n"} =
               Yaml.put(text, ["models", "cheap"], "c")
    end

    test "Windows line endings and a byte order mark stay as they were" do
      text = <<0xEF, 0xBB, 0xBF>> <> "# mine\r\nmodels:\r\n  default: a\r\nmax_turns: 3\r\n"

      assert {:ok, edited} = Yaml.put(text, ["models", "cheap"], "b")
      assert edited == <<0xEF, 0xBB, 0xBF>> <> "# mine\r\nmodels:\r\n  default: a\r\n  cheap: b\r\nmax_turns: 3\r\n"
    end

    test "a key of the same name somewhere else is not the key" do
      text = "x-notes:\n  max_turns: 1\nmax_turns: 2\n"
      assert {:ok, "x-notes:\n  max_turns: 1\nmax_turns: 5\n"} = Yaml.put(text, ["max_turns"], 5)
    end

    test "refuses a file that is not YAML, or not a map" do
      assert :error = Yaml.put("a: [unclosed\n", ["max_turns"], 3)
      assert :error = Yaml.put("- a\n- b\n", ["max_turns"], 3)
    end
  end

  describe "edit/2" do
    @file_text """
    # mine
    provider: openai
    auth_token: old     # the old spelling
    model: flat-default

    models:
      cheap: q   # small
      windows:
        q: 32000

    max_turns: 40
    """

    test "removes a key with the lines beneath it, changes and adds the rest, and keeps every other line" do
      map =
        @file_text
        |> YamlElixir.read_from_string()
        |> elem(1)
        |> Map.drop(["auth_token", "model"])
        |> Map.merge(%{"api_key" => "new", "auth" => "bearer"})
        |> put_in(["models", "default"], "flat-default")
        |> update_in(["models"], &Map.delete(&1, "windows"))

      assert {:ok, text} = Yaml.edit(@file_text, map)

      assert text == """
             # mine
             provider: openai

             models:
               cheap: q   # small
               default: flat-default

             max_turns: 40
             api_key: new
             auth: bearer
             """
    end

    test "a map left empty is written as {}, and a new map or list one entry a line" do
      map = %{
        "provider" => "openai",
        "auth_token" => "old",
        "model" => "flat-default",
        "models" => %{},
        "max_turns" => 40,
        "read_roots" => ["~/src/dep", "{env:HOME}/x"],
        "providers" => %{"gw" => %{"type" => "openai", "models" => %{"m" => %{"context" => 128_000}}}}
      }

      assert {:ok, text} = Yaml.edit(@file_text, map)
      assert YamlElixir.read_from_string(text) == {:ok, map}
      assert text =~ "\nmodels: {}\n\nmax_turns: 40\n"

      assert String.ends_with?(
               text,
               "providers:\n  gw:\n    models:\n      m:\n        context: 128000\n    type: openai\n" <>
                 "read_roots:\n  - ~/src/dep\n  - \"{env:HOME}/x\"\n"
             )
    end

    test "nothing changed is the same text" do
      {:ok, map} = YamlElixir.read_from_string(@file_text)
      assert {:ok, @file_text} = Yaml.edit(@file_text, map)
    end
  end
end
