defmodule Troupe.Config.PermissionsTest do
  @moduledoc """
  Per-tool permission rules as configuration (#658): read strictly from
  every scope, kept from all of them with where each came from, the strictest holding,
  and shown by `--explain` and `config.get`.
  """

  # The managed file's path is the application environment's, which is the whole VM's: a
  # test that moves it runs alone.
  use ExUnit.Case, async: false

  alias Troupe.Config
  alias Troupe.Config.{Permissions, Settings}

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-rules-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    user = Path.join(base, "user.yaml")
    File.write!(user, "version: 1\n")

    managed = Path.join(base, "managed.yaml")
    cache = Path.join(base, "state/organisation.json")
    previous = Application.get_env(:troupe_core, :organisation)

    Application.put_env(:troupe_core, :organisation,
      managed_path: managed,
      cache_path: cache,
      keys_path: Path.join(base, "state/plane-keys.json")
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:troupe_core, :organisation, previous),
        else: Application.delete_env(:troupe_core, :organisation)

      File.rm_rf!(base)
    end)

    %{
      base: base,
      ws: ws,
      user: user,
      managed: managed,
      project: Path.join(ws, ".troupe/config.yaml"),
      local: Path.join(ws, ".troupe/config.local.yaml")
    }
  end

  defp resolve(ctx, opts \\ []),
    do: Config.resolve(Keyword.get(opts, :workspace, ctx.ws), [], [user_path: ctx.user] ++ opts)

  defp load!(ctx, opts \\ []) do
    assert {:ok, config, _layers} = resolve(ctx, opts)
    config
  end

  defp trust(ctx),
    do:
      File.write!(
        ctx.user,
        File.read!(ctx.user) <> "trusted_workspaces:\n  - #{Jason.encode!(ctx.ws)}\n"
      )

  defp decide(config, tool, args), do: Permissions.decide(config.permissions, tool, args, "/repo")

  defp action(config, tool, args) do
    case decide(config, tool, args) do
      {action, _rule} -> action
      nil -> nil
    end
  end

  describe "the strict reader" do
    test "refuses a malformed rule, naming the file, the line and what to write", ctx do
      File.write!(ctx.user, "version: 1\npermissions:\n  deny:\n    - Bash(git push)\n")

      assert {:error, error} = resolve(ctx)
      message = Exception.message(error)
      assert message =~ "user.yaml"
      assert message =~ "permissions.deny"
      assert message =~ "Troupe's is shell"

      for {rule, says} <- [
            {"shell(git * --force)", "may only end"},
            {"shell(npm test:*)", "drop the :*"},
            {"mcp.github.create_issue", "mcp(github.create_issue)"},
            {"read_branch(x)", "takes no pattern"},
            {"Shell", "lower case"},
            {"shell()", "empty pattern"}
          ] do
        File.write!(ctx.user, "version: 1\npermissions:\n  ask: [#{Jason.encode!(rule)}]\n")
        assert {:error, error} = resolve(ctx), rule
        assert Exception.message(error) =~ says, rule
      end

      File.write!(ctx.user, "version: 1\npermissions:\n  deny: shell\n")
      assert {:error, error} = resolve(ctx)
      assert Exception.message(error) =~ "permissions.deny must be a list of rules"
    end

    test "warns about a tool name near a built-in's, and an ask for a tool that never asks",
         ctx do
      File.write!(ctx.user, "version: 1\npermissions:\n  deny: [shel]\n  ask: [todo_write]\n")

      config = load!(ctx)

      assert Enum.any?(
               config.warnings,
               &(&1 =~ "shel is not a tool Troupe has; did you mean shell?")
             )

      assert Enum.any?(config.warnings, &(&1 =~ "todo_write runs inside the agent"))
      # Kept all the same: a host may add a tool of that name.
      assert Enum.map(config.permissions, & &1.text) == ["shel", "todo_write"]
    end

    test "an unknown action is a key it does not know", ctx do
      File.write!(ctx.user, "version: 1\npermissions:\n  block: [shell]\n")
      config = load!(ctx)
      assert Enum.any?(config.warnings, &(&1 =~ "permissions.block is not a setting"))
    end
  end

  describe "every scope's rules" do
    test "are kept together with where each came from, an untrusted project's allow held", ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  permissions:\n    ask: [\"shell(git push)\"]\ndefaults:\n  permissions:\n    deny: [web_fetch]\n"
      )

      File.write!(ctx.user, "version: 1\npermissions:\n  allow: [\"shell(git *)\"]\n")

      File.write!(
        ctx.project,
        "permissions:\n  deny: [\"read_file(secrets/**)\"]\n  allow: [write_file]\n"
      )

      File.write!(ctx.local, "permissions:\n  ask: [\"mcp(github)\"]\n")

      assert {:ok, config, layers} = resolve(ctx)

      assert Enum.map(layers.rules, &{&1.action, &1.text, &1.layer}) == [
               {:deny, "web_fetch", :org},
               {:allow, "shell(git *)", :user},
               {:deny, "read_file(secrets/**)", :project},
               {:allow, "write_file", :project},
               {:ask, "mcp(github)", :local},
               {:ask, "shell(git push)", :enforced}
             ]

      held = Enum.find(layers.rules, &(&1.text == "write_file"))
      assert held.ignored =~ "trusted workspace"
      refute Enum.any?(config.permissions, &(&1.text == "write_file"))
      assert Enum.find(layers.rules, &(&1.layer == :enforced)).source == ctx.managed

      # Trusted, the project's allow applies.
      trust(ctx)
      assert Enum.any?(load!(ctx).permissions, &(&1.text == "write_file"))
    end

    test "a higher file adds to a lower one's rules rather than replacing them", ctx do
      File.write!(ctx.user, "version: 1\npermissions:\n  deny: [\"shell(rm -rf)\"]\n")
      File.write!(ctx.project, "permissions:\n  deny: [\"shell(git push)\"]\n")

      config = load!(ctx)
      assert action(config, "shell", %{"command" => "rm -rf /"}) == :deny
      assert action(config, "shell", %{"command" => "git push"}) == :deny
    end

    test "on a pod a project's allow is never read, and its deny is", ctx do
      trust(ctx)
      File.write!(ctx.project, "permissions:\n  deny: [\"shell(git push)\"]\n  allow: [shell]\n")

      config = load!(ctx, trust: :never)
      assert action(config, "shell", %{"command" => "git push"}) == :deny
      assert action(config, "shell", %{"command" => "ls"}) == nil
    end
  end

  describe "the strictest holds" do
    test "deny beats ask beats allow, whatever the scope", ctx do
      File.write!(ctx.user, "version: 1\npermissions:\n  deny: [\"shell(git push)\"]\n")
      trust(ctx)

      File.write!(
        ctx.project,
        "permissions:\n  allow: [\"shell(git push)\", \"shell(ls)\"]\n  ask: [\"shell(ls -la)\"]\n"
      )

      config = load!(ctx)
      assert {:deny, rule} = decide(config, "shell", %{"command" => "git push origin main"})
      assert rule.layer == :user
      assert action(config, "shell", %{"command" => "ls -la"}) == :ask
      assert action(config, "shell", %{"command" => "ls"}) == :allow
    end

    test "an organisation's enforced ask beats a person's allow", ctx do
      File.write!(ctx.managed, "enforced:\n  permissions:\n    ask: [shell]\n")
      File.write!(ctx.user, "version: 1\npermissions:\n  allow: [\"shell(git status)\"]\n")

      assert {:ask, rule} = decide(load!(ctx), "shell", %{"command" => "git status"})
      assert rule.layer == :enforced
      assert Permissions.describe(rule) =~ "what your organisation enforces"
    end

    test "inside one file the more specific rule decides, and of two as specific the stricter",
         ctx do
      File.write!(ctx.user, """
      version: 1
      permissions:
        deny: [shell, "write_file(lib/secret.ex)"]
        allow: ["shell(git status)", "write_file(lib/**)", "write_file(lib/secret.ex)"]
      """)

      config = load!(ctx)
      assert action(config, "shell", %{"command" => "git status"}) == :allow
      assert action(config, "shell", %{"command" => "git push"}) == :deny
      assert action(config, "write_file", %{"path" => "lib/a.ex"}) == :allow
      assert action(config, "write_file", %{"path" => "lib/secret.ex"}) == :deny
    end

    test "managed_permission_rules_only holds every allow but the organisation's", ctx do
      File.write!(
        ctx.managed,
        "enforced:\n  managed_permission_rules_only: true\ndefaults:\n  permissions:\n    allow: [read_file]\n"
      )

      File.write!(ctx.user, "version: 1\npermissions:\n  allow: [shell]\n  deny: [web_fetch]\n")

      assert {:ok, config, layers} = resolve(ctx)

      assert Enum.find(layers.rules, &(&1.text == "shell")).ignored =~
               "managed_permission_rules_only"

      assert action(config, "shell", %{"command" => "ls"}) == nil
      assert action(config, "read_file", %{"path" => "a"}) == :allow
      assert action(config, "web_fetch", %{"url" => "https://example.com"}) == :deny
    end
  end

  describe "what a pattern matches" do
    defp rules(ctx, yaml) do
      File.write!(ctx.user, "version: 1\npermissions:\n" <> yaml)
      load!(ctx)
    end

    test "a shell rule is a prefix of each command a line runs", ctx do
      config =
        rules(ctx, "  deny: [\"shell(git push)\"]\n  allow: [\"shell(ls)\", \"shell(cat)\"]\n")

      assert action(config, "shell", %{"command" => "git push"}) == :deny
      assert action(config, "shell", %{"command" => "git  push  --force"}) == :deny
      assert action(config, "shell", %{"command" => "git pushx"}) == nil
      assert action(config, "shell", %{"command" => "ls && git push"}) == :deny
      assert action(config, "shell", %{"command" => "ls; FOO=1 git push"}) == :deny
      assert action(config, "shell", %{"command" => "echo $(git push)"}) == :deny
      assert action(config, "shell", %{"command" => "echo 'a; git push'"}) == nil
      # An allow covers a line only when it covers every command, and no substitution.
      assert action(config, "shell", %{"command" => "ls | cat"}) == :allow
      assert action(config, "shell", %{"command" => "ls 2>&1 | cat"}) == :allow
      assert action(config, "shell", %{"command" => "ls && rm -rf x"}) == nil
      assert action(config, "shell", %{"command" => "ls $(rm -rf x)"}) == nil
      assert action(config, "shell", %{"command" => "cat `whoami`"}) == nil

      config = rules(ctx, "  deny: [\"shell(git push*)\", \"shell(rm *)\"]\n")
      assert action(config, "shell", %{"command" => "git pushx"}) == :deny
      assert action(config, "shell", %{"command" => "rm"}) == :deny
      assert action(config, "shell", %{"command" => "rmdir x"}) == nil
    end

    test "a file tool's is a path glob, from the workspace", ctx do
      config =
        rules(
          ctx,
          "  deny: [\"read_file(secrets)\", \"edit_file(**/*.lock)\", \"grep(/etc/**)\"]\n"
        )

      assert action(config, "read_file", %{"path" => "secrets"}) == :deny
      assert action(config, "read_file", %{"path" => "secrets/key.pem"}) == :deny
      assert action(config, "read_file", %{"path" => "./src/../secrets/key.pem"}) == :deny
      assert action(config, "read_file", %{"path" => "session:/secrets/key.pem"}) == :deny
      assert action(config, "read_file", %{"path" => "/repo/secrets/key.pem"}) == :deny
      assert action(config, "read_file", %{"path" => "secrets2/x"}) == nil
      assert action(config, "edit_file", %{"path" => "mix.lock"}) == :deny
      assert action(config, "edit_file", %{"path" => "deep/er/yarn.lock"}) == :deny
      assert action(config, "grep", %{"path" => "/etc/passwd"}) == :deny
      assert action(config, "grep", %{}) == nil
    end

    test "an MCP rule is server.tool, or a server, for a server's and a client's tools", ctx do
      config = rules(ctx, "  deny: [\"mcp(github.delete_*)\"]\n  ask: [\"mcp(jira)\"]\n")

      assert action(config, "mcp.github.delete_repo", %{}) == :deny
      assert action(config, "client.github.delete_repo", %{}) == :deny
      assert action(config, "mcp.github.list", %{}) == nil
      assert action(config, "mcp.jira.create", %{}) == :ask
      assert action(config, "mcp.jirax.create", %{}) == nil
      assert action(rules(ctx, "  deny: [mcp]\n"), "mcp.any.thing", %{}) == :deny
    end
  end

  describe "where they show" do
    test "--explain lists every rule with its file, and why one is held", ctx do
      File.write!(ctx.managed, "enforced:\n  permissions:\n    deny: [\"shell(git push)\"]\n")
      File.write!(ctx.project, "permissions:\n  allow: [shell]\n")

      {text, 0} = Config.explain(ctx.ws, nil, user_path: ctx.user)
      assert text =~ "permission rules"
      assert text =~ ~r/deny\s+shell\(git push\)\s+enforced\s+.*managed\.yaml/
      assert text =~ ~r/allow\s+shell\s+project/
      assert text =~ "ignored: a project's file sets it only in a trusted workspace"
      refute text =~ "permissions.deny"

      {only, 0} = Config.explain(ctx.ws, "permissions", user_path: ctx.user)
      assert only =~ "shell(git push)"

      {json, 0} = Config.explain(ctx.ws, nil, user_path: ctx.user, json: true)
      rules = Jason.decode!(json)["permissions"]

      assert [
               %{"rule" => "shell", "scope" => "project", "ignored" => "a project's" <> _},
               enforced
             ] = rules

      assert %{"action" => "deny", "rule" => "shell(git push)", "scope" => "enforced"} = enforced
    end

    test "--explain says when there are none, only when asked", ctx do
      {text, 0} = Config.explain(ctx.ws, nil, user_path: ctx.user)
      refute text =~ "permission rules"
      {only, 0} = Config.explain(ctx.ws, "permissions", user_path: ctx.user)
      assert only =~ "permission rules: none"
    end

    test "config.get carries every rule with where it came from", ctx do
      File.write!(ctx.managed, "enforced:\n  permissions:\n    ask: [\"mcp(github)\"]\n")

      answer = Settings.describe(ctx.ws)

      assert [
               %{
                 "action" => "ask",
                 "rule" => "mcp(github)",
                 "scope" => "enforced",
                 "ignored" => nil
               } = rule
             ] =
               answer["permissions"]

      assert rule["source"] =~ "managed.yaml"
      refute Enum.any?(answer["keys"], &String.starts_with?(&1["key"], "permissions"))
    end
  end
end
