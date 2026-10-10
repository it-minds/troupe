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

    # The transport follows from which key is set, so `type` is dropped; the headers are
    # carried (Decision 820), as written when the file is read where it is.
    assert parsed.servers["github"] == %{
             "url" => "https://api.githubcopilot.com/mcp/",
             "headers" => %{"Authorization" => "Bearer x"}
           }

    assert parsed.skipped == []
    assert parsed.warnings == []
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

  describe "headers (Decision 820)" do
    # Each tool's file as it writes a server over HTTP with a key.
    @claude_code """
    {"mcpServers": {"tracker": {"type": "http", "url": "https://mcp.example.com/mcp",
      "headers": {"Authorization": "Bearer ${TRACKER_TOKEN}", "X-Team": "core"},
      "headersHelper": "/usr/local/bin/print-headers"}}}
    """

    @cursor """
    {"mcpServers": {"docs": {"url": "https://docs.example.com/mcp",
      "headers": {"X-Api-Key": "${env:DOCS_KEY}"}}}}
    """

    @vs_code """
    {
      "inputs": [{"id": "key", "type": "promptString", "password": true}],
      "servers": {
        "search": {"type": "http", "url": "https://search.example.com/mcp", "headers": {"X-Key": "${env:SEARCH_KEY}"}},
        "asks": {"type": "http", "url": "https://asks.example.com/mcp", "headers": {"X-Key": "${input:key}"}},
      }
    }
    """

    @opencode """
    {
      "$schema": "https://opencode.ai/config.json",
      "model": "anthropic/claude-sonnet-5",
      "mcp": {
        "wiki": {"type": "remote", "url": "https://wiki.example.com/mcp", "enabled": true,
                 "headers": {"Authorization": "Bearer {env:WIKI_TOKEN}"}, "oauth": false, "timeout": 8000},
        "files": {"type": "local", "command": ["npx", "-y", "files-mcp"], "environment": {"ROOT": "/srv"}, "enabled": false},
        "vault": {"type": "remote", "url": "https://vault.example.com/mcp", "headers": {"X-Key": "{file:~/.vault-key}"}}
      }
    }
    """

    test "Claude Code's are carried, ${VAR} read as {env:VAR}, and its headersHelper said not run" do
      assert {:ok, parsed} = Import.parse(@claude_code)

      assert parsed.servers["tracker"]["headers"] == %{
               "Authorization" => "Bearer {env:TRACKER_TOKEN}",
               "X-Team" => "core"
             }

      assert [helper] = parsed.warnings
      assert helper =~ "tracker: headersHelper is a command Troupe does not run"
    end

    test "Cursor's and VS Code's are carried; a VS Code ${input:…} in one still skips the server" do
      assert {:ok, cursor} = Import.parse(@cursor)
      assert cursor.servers["docs"]["headers"] == %{"X-Api-Key" => "{env:DOCS_KEY}"}

      assert {:ok, vs_code} = Import.parse(@vs_code)
      assert vs_code.servers["search"]["headers"] == %{"X-Key" => "{env:SEARCH_KEY}"}
      assert [%{name: "asks", reason: reason}] = vs_code.skipped
      assert reason =~ "${input:"
    end

    test "opencode's mcp block: remote with headers, local as a command, enabled false as off, {file:…} skipped" do
      assert {:ok, parsed} = Import.parse(@opencode)

      assert parsed.servers["wiki"] == %{
               "url" => "https://wiki.example.com/mcp",
               "headers" => %{"Authorization" => "Bearer {env:WIKI_TOKEN}"}
             }

      assert parsed.servers["files"] == %{
               "command" => "npx",
               "args" => ["-y", "files-mcp"],
               "env" => %{"ROOT" => "/srv"},
               "disabled" => true
             }

      assert [%{name: "vault", reason: reason}] = parsed.skipped
      assert reason =~ "{file:…} reference only opencode reads"
    end

    test "a copy writes a header written out as the {env:VAR} that reads it, and says which to set" do
      text = """
      {"mcpServers": {
        "Git Hub": {"url": "https://git.example.com/mcp",
                    "headers": {"Authorization": "Bearer not-a-real-token", "X-Api-Key": "k-123",
                                "X-Team": "{env:TEAM}", "X-Trace": "${TRACE_ID}", "X-Empty": ""}}
      }}
      """

      assert {:ok, read} = Import.parse(text)
      assert read.servers["git-hub"]["headers"]["X-Api-Key"] == "k-123"

      assert {:ok, copied} = Import.parse(text, copy: true)

      assert copied.servers["git-hub"]["headers"] == %{
               "Authorization" => "Bearer {env:GIT_HUB_AUTHORIZATION}",
               "X-Api-Key" => "{env:GIT_HUB_X_API_KEY}",
               "X-Team" => "{env:TEAM}",
               "X-Trace" => "{env:TRACE_ID}",
               "X-Empty" => ""
             }

      # The warnings name the variable and never the value.
      refute Enum.any?(copied.warnings, &(&1 =~ "not-a-real-token" or &1 =~ "k-123"))

      assert ("git-hub: the header Authorization is copied as Bearer {env:GIT_HUB_AUTHORIZATION}, " <>
                "not as its value; set GIT_HUB_AUTHORIZATION to the credential after Bearer in the " <>
                "file it came from") in copied.warnings

      assert Enum.any?(copied.warnings, &(&1 =~ "set GIT_HUB_X_API_KEY to the value in the file"))
    end

    test "headers that are not a map of strings refuse the server" do
      assert {:ok, %{skipped: [%{name: "bad", reason: "headers is not a map"}]}} =
               Import.parse(
                 ~s({"mcpServers": {"bad": {"url": "https://x.test/mcp", "headers": ["X-Key: y"]}}})
               )

      assert {:ok, %{skipped: [%{name: "odd", reason: "headers is not a map of strings"}]}} =
               Import.parse(
                 ~s({"mcpServers": {"odd": {"url": "https://x.test/mcp", "headers": {"X-Key": {"a": 1}}}}})
               )
    end
  end

  describe "env (Decision 825)" do
    test "a copy writes a variable written out as the {env:VAR} that reads it, and says which to set" do
      text = """
      {"mcpServers": {
        "Git Hub": {"command": "npx", "args": ["-y", "github-mcp"],
                    "env": {"GITHUB_TOKEN": "not-a-real-token", "PORT": 8080, "DEBUG": true,
                            "HOME_DIR": "${HOME}", "AUTH": "Bearer also-not-real", "EMPTY": ""}}
      }}
      """

      # Read where it is, the values are as written.
      assert {:ok, read} = Import.parse(text)
      assert read.servers["git-hub"]["env"]["GITHUB_TOKEN"] == "not-a-real-token"
      assert read.warnings == ["Git Hub is imported as git-hub"]

      assert {:ok, copied} = Import.parse(text, copy: true)

      assert copied.servers["git-hub"]["env"] == %{
               "GITHUB_TOKEN" => "{env:GIT_HUB_GITHUB_TOKEN}",
               "PORT" => "{env:GIT_HUB_PORT}",
               "DEBUG" => "{env:GIT_HUB_DEBUG}",
               "HOME_DIR" => "{env:HOME}",
               "AUTH" => "Bearer {env:GIT_HUB_AUTH}",
               "EMPTY" => ""
             }

      refute inspect(copied) =~ "not-a-real-token"
      refute inspect(copied) =~ "also-not-real"

      assert ("git-hub: the variable GITHUB_TOKEN is copied as {env:GIT_HUB_GITHUB_TOKEN}, " <>
                "not as its value; set GIT_HUB_GITHUB_TOKEN to the value in the file it came from") in copied.warnings

      assert Enum.any?(
               copied.warnings,
               &(&1 =~ "set GIT_HUB_AUTH to the credential after Bearer")
             )
    end
  end

  describe "Codex's config.toml (Decision 825)" do
    @codex """
    model = "a-model"

    [mcp_servers.docs]
    command = "docs-server"
    args = ["--port", "4000"]
    cwd = "tools"
    env_vars = ["PATH_EXTRA"]
    startup_timeout_sec = 20
    tool_timeout_sec = 90
    enabled_tools = ["search"]

    [mcp_servers.docs.env]
    LOG_LEVEL = "${LEVEL}"

    [mcp_servers.Figma]
    url = "https://mcp.example.com/mcp"
    bearer_token_env_var = "FIGMA_TOKEN"
    http_headers = { "X-Region" = "us" }
    env_http_headers = { "X-Org" = "FIGMA_ORG" }
    http_headers_helper = "print-headers"
    enabled = false

    [mcp_servers.broken]
    url = "https://broken.example.com/mcp"
    env_http_headers = { "X-Org" = "not a name" }
    """

    test "its [mcp_servers] tables import as the others' entries, and what is not carried is said" do
      assert {:ok, parsed} = Import.parse(@codex, format: :toml)

      assert parsed.servers["docs"] == %{
               "command" => "docs-server",
               "args" => ["--port", "4000"],
               "cd" => "tools",
               "env" => %{"LOG_LEVEL" => "{env:LEVEL}"},
               "timeout_ms" => 90_000
             }

      assert parsed.servers["figma"] == %{
               "url" => "https://mcp.example.com/mcp",
               "headers" => %{
                 "Authorization" => "Bearer {env:FIGMA_TOKEN}",
                 "X-Region" => "us",
                 "X-Org" => "{env:FIGMA_ORG}"
               },
               "disabled" => true
             }

      assert [%{name: "broken", reason: reason}] = parsed.skipped
      assert reason == "env_http_headers is not a map of header to variable name"

      assert "docs: enabled_tools is not carried: every tool the server lists is offered, and each asks before it runs" in parsed.warnings

      assert Enum.any?(
               parsed.warnings,
               &(&1 =~ "figma: http_headers_helper is a command Troupe does not run")
             )

      assert "Figma is imported as figma" in parsed.warnings
    end

    test "a copy writes a header written out as the {env:VAR} that reads it" do
      assert {:ok, copied} = Import.parse(@codex, format: :toml, copy: true)

      assert copied.servers["figma"]["headers"] == %{
               "Authorization" => "Bearer {env:FIGMA_TOKEN}",
               "X-Region" => "{env:FIGMA_X_REGION}",
               "X-Org" => "{env:FIGMA_ORG}"
             }
    end

    test "a file with no [mcp_servers], or one that is not TOML, says so" do
      assert {:error, "not a config.toml with [mcp_servers] tables"} =
               Import.parse("model = \"x\"\n", format: :toml)

      assert {:error, "not TOML: line 1: expected a key"} =
               Import.parse("{\"mcpServers\": {}}", format: :toml)

      assert Import.format("/home/me/.codex/config.toml") == :toml
      assert Import.format("/home/me/.mcp.json") == :json
    end
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
