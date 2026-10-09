defmodule Troupe.Config.TOMLTest do
  @moduledoc """
  The narrow TOML reader an import of Codex's `config.toml` goes through (Decision 825):
  what a Codex file holds read into maps, and anything else an error naming the line.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config.TOML

  test "a Codex config.toml: top-level keys, tables, sub-tables, dotted and quoted keys" do
    text = """
    # Codex's own settings, which the import passes over.
    model = "a-model"
    approval_policy = "on-request"

    [profiles.fast]
    model = "b-model"

    [mcp_servers.docs]
    command = "docs-server"
    args = ["--port", "4000"]   # a comment after a value
    env = { "API_KEY" = "k", LOG_LEVEL = 'debug' }
    startup_timeout_sec = 20
    tool_timeout_sec = 1.5

    [mcp_servers."my server".env]
    TOKEN = "t"

    [mcp_servers.figma]
    url = "https://mcp.example.com/mcp"
    http_headers.X-Region = "us"
    enabled = false
    """

    assert {:ok, doc} = TOML.decode(text)
    assert doc["model"] == "a-model"
    assert doc["profiles"] == %{"fast" => %{"model" => "b-model"}}

    assert doc["mcp_servers"]["docs"] == %{
             "command" => "docs-server",
             "args" => ["--port", "4000"],
             "env" => %{"API_KEY" => "k", "LOG_LEVEL" => "debug"},
             "startup_timeout_sec" => 20,
             "tool_timeout_sec" => 1.5
           }

    assert doc["mcp_servers"]["my server"] == %{"env" => %{"TOKEN" => "t"}}

    assert doc["mcp_servers"]["figma"] == %{
             "url" => "https://mcp.example.com/mcp",
             "http_headers" => %{"X-Region" => "us"},
             "enabled" => false
           }
  end

  test "the four kinds of string" do
    text = ~S"""
    basic = "tab\there \"quoted\" \u00e9 \U0001F600 back\\slash"
    literal = 'C:\Users\me'
    multi = \"""
    one
    two \
       three\"""
    raw = '''
    first
    'quoted' ''still''\n'''
    quotes = \"""a ""b"" c\"""""
    """

    assert {:ok, doc} = TOML.decode(text)
    assert doc["basic"] == "tab\there \"quoted\" é 😀 back\\slash"
    assert doc["literal"] == "C:\\Users\\me"
    assert doc["multi"] == "one\ntwo three"
    assert doc["raw"] == "first\n'quoted' ''still''\\n"
    assert doc["quotes"] == "a \"\"b\"\" c\"\""
  end

  test "numbers, booleans, dates, arrays over lines and arrays of tables" do
    text = """
    int = 1_000
    neg = -17
    hex = 0xff
    oct = 0o17
    bin = 0b101
    float = 6.5e-1
    exp = 1e3
    inf = -inf
    yes = true
    when = 1979-05-27 07:32:00Z
    day = 1979-05-27
    list = [
      1,  # one
      [2, 3],
      { a = "b" },
    ]

    [[servers]]
    name = "a"

    [[servers]]
    name = "b"

    [servers.extra]
    on = true
    """

    assert {:ok, doc} = TOML.decode(text)

    assert Map.take(doc, ~w(int neg hex oct bin float exp inf yes when day)) == %{
             "int" => 1000,
             "neg" => -17,
             "hex" => 255,
             "oct" => 15,
             "bin" => 5,
             "float" => 0.65,
             "exp" => 1000.0,
             "inf" => "-inf",
             "yes" => true,
             "when" => "1979-05-27 07:32:00Z",
             "day" => "1979-05-27"
           }

    assert doc["list"] == [1, [2, 3], %{"a" => "b"}]
    assert doc["servers"] == [%{"name" => "a"}, %{"name" => "b", "extra" => %{"on" => true}}]
  end

  test "what it cannot read is an error naming the line" do
    assert {:error, "line 2: expected ="} = TOML.decode("a = 1\nb 2\n")

    assert {:error, "line 1: a string is not closed on its line"} =
             TOML.decode("a = \"open\nb = 1\n")

    assert {:error, "line 3: expected the end of the line"} = TOML.decode("a = 1\n\nb = 1 2\n")
    assert {:error, "line 1: what is not a value TOML has"} = TOML.decode("a = what\n")
    assert {:error, "line 2: a is a value, not a table"} = TOML.decode("a = 1\n[a.b]\n")
    assert {:error, "line 1: \\uD800 is not a character" <> _} = TOML.decode(~S(a = "\uD800"))
  end

  test "a byte-order mark and Windows line endings are read as any other file" do
    assert {:ok, %{"a" => %{"b" => "c"}}} = TOML.decode("\uFEFF[a]\r\nb = \"c\"\r\n")
  end
end
