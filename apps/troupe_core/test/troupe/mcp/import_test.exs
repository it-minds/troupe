defmodule Troupe.MCP.ImportTest do
  @moduledoc """
  Reading the MCP files other tools write (Decision 700): Claude Code's and Claude
  Desktop's `mcpServers`, Cursor's with `disabled`, VS Code's `servers` with comments
  and `${env:…}`, and Troupe's own. What each becomes is the entry Troupe stores; what
  cannot become one is skipped and said so. Pure: nothing here touches a file.
  """

  use ExUnit.Case, async: true

  alias Troupe.MCP.Import

  test "a Claude Code .mcp.json: stdio servers with env, and an http one" do
    text = """
    {
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
          "env": {"LOG_LEVEL": "debug"}
        },
        "github": {"type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer x"}}
      }
    }
    """

    assert {:ok, parsed} = Import.parse(text)

    assert parsed.servers["filesystem"] == %{
             "command" => "npx",
             "args" => ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
             "env" => %{"LOG_LEVEL" => "debug"}
           }

    # The transport follows from which key is set; `type` and `headers` are dropped, and
    # a dropped header is said out loud since the server may need it.
    assert parsed.servers["github"] == %{"url" => "https://api.githubcopilot.com/mcp/"}
    assert parsed.skipped == []
    assert ["github: headers are not carried" <> _] = parsed.warnings
  end

  test "a VS Code mcp.json: `servers`, comments, ${env:VAR} translated, ${input:…} skipped" do
    text = """
    {
      // VS Code allows comments and trailing commas.
      "inputs": [{"id": "token", "type": "promptString"}],
      "servers": {
        "docs": {"type": "stdio", "command": "uvx", "args": ["docs-mcp"], "env": {"TOKEN": "${env:DOCS_TOKEN}"},},
        "secret": {"command": "x", "env": {"API_KEY": "${input:token}"}},
      }
    }
    """

    assert {:ok, parsed} = Import.parse(text)
    assert parsed.servers["docs"]["env"] == %{"TOKEN" => "{env:DOCS_TOKEN}"}
    refute Map.has_key?(parsed.servers, "secret")
    assert [%{name: "secret", reason: reason}] = parsed.skipped
    assert reason =~ "${input:"
  end

  test "Cursor's shape: cwd, disabled, and Claude Code's ${VAR:-default} in args" do
    text =
      ~s({"mcpServers": {"db": {"command": "db-mcp", "cwd": "/srv/db", "disabled": true, "args": ["--dsn", "${DSN:-postgres://localhost}"]}}})

    assert {:ok, parsed} = Import.parse(text)
    assert parsed.servers["db"]["cd"] == "/srv/db"
    assert parsed.servers["db"]["disabled"] == true
    assert parsed.servers["db"]["args"] == ["--dsn", "{env:DSN}"]
    assert Enum.any?(parsed.warnings, &(&1 =~ "default is dropped"))
  end

  test "a bare map of name to entry, and names Troupe cannot spell a tool with" do
    assert {:ok, parsed} =
             Import.parse(
               ~s({"My Server": {"command": "srv"}, "ok_one": {"url": "https://x.test/mcp"}})
             )

    assert Map.keys(parsed.servers) == ["my-server", "ok_one"]
    assert ["My Server is imported as my-server"] = parsed.warnings

    refute Import.valid_name?("with.dot")
    refute Import.valid_name?("")
    assert Import.valid_name?("fs-1")
    assert Import.sanitize_name("Weird!!Name") == "weird-name"
  end

  test "an entry that is not a server is skipped with a reason, and a file that is not one is an error" do
    assert {:ok, parsed} =
             Import.parse(
               ~s({"mcpServers": {"both": {"command": "a", "url": "b"}, "neither": {}, "odd": {"command": 3}}})
             )

    assert parsed.servers == %{}

    assert Enum.map(parsed.skipped, & &1.name) == ["both", "neither", "odd"]
    assert Enum.find(parsed.skipped, &(&1.name == "both")).reason =~ "both a command and a url"
    assert Enum.find(parsed.skipped, &(&1.name == "neither")).reason =~ "neither"
    assert Enum.find(parsed.skipped, &(&1.name == "odd")).reason =~ "command is not a string"

    assert {:error, "not JSON" <> _} = Import.parse("{not json")
    assert {:error, "the file is not a JSON object"} = Import.parse("[1, 2]")
    assert {:error, "no mcpServers object in the file"} = Import.parse(~s({"version": 1}))
  end

  test "Troupe's own permission and timeout are kept; a bad permission is the default" do
    assert {:ok, %{servers: %{"a" => a, "b" => b}}} =
             Import.parse(
               ~s({"mcpServers": {"a": {"command": "x", "permission": "auto", "timeout_ms": 5000}, "b": {"command": "y", "permission": "yes"}}})
             )

    assert a == %{"command" => "x", "permission" => "auto", "timeout_ms" => 5000}
    assert b == %{"command" => "y"}
  end
end
