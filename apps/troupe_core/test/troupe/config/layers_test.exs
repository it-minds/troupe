defmodule Troupe.Config.LayersTest do
  @moduledoc """
  How the config files are read (Decision 686): strictly, merged by key, old spellings
  still loading with a warning, no unset `{env:VAR}` ever sent anywhere, and a
  workspace's own files setting the keys that decide what may run only once the
  workspace is trusted.

  Every test reads a user file of its own (`user_path:`), so the suite's shared config
  directory, which trusts the temp directory, is not what decides these.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config
  alias Troupe.Config.Trust
  alias Troupe.Session.Approvals

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-layers-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, ws: ws, user: Path.join(base, "user.yaml"), project: Path.join(ws, ".troupe/config.yaml")}
  end

  defp resolve(ctx, overrides \\ [], opts \\ []),
    do: Config.resolve(ctx.ws, overrides, [user_path: ctx.user] ++ opts)

  defp load!(ctx, overrides \\ [], opts \\ []) do
    {:ok, config, _layers} = resolve(ctx, overrides, opts)
    config
  end

  defp refused!(ctx, opts \\ []) do
    assert {:error, %Config.Error{} = error} = resolve(ctx, [], opts)
    Exception.message(error)
  end

  defp trust(ctx, extra \\ ""),
    do: File.write!(ctx.user, "trusted_workspaces:\n  - #{Jason.encode!(ctx.ws)}\n" <> extra)

  describe "a file Troupe refuses" do
    test "is not YAML: the load fails naming the file and line, and nothing loads as {}", ctx do
      File.write!(ctx.user, "models:\n  default: x\n    cheap: [unclosed\n")
      message = refused!(ctx)
      assert message =~ "#{ctx.user}:"
      assert message =~ "is not valid YAML"
    end

    test "is not a map of settings", ctx do
      File.write!(ctx.user, "- a\n- b\n")
      assert refused!(ctx) =~ "#{ctx.user}: must be a map of settings"
    end

    test "has a value of the wrong type: file, line, key and what to write", ctx do
      File.write!(ctx.user, "max_turns: 40\nmax_tokens: lots\n")
      assert refused!(ctx) =~ "#{ctx.user}:2: max_tokens must be a whole number, at least 1, not \"lots\""
    end

    test "has an enum value nobody knows, in each place there is one", ctx do
      trust(ctx)

      for {yaml, expected} <- [
            {"approvals: always\n", "approvals must be one of wait, deny, not \"always\""},
            {"auth: token\n", "auth must be one of api_key, bearer, not \"token\""},
            {"mcp:\n  fs:\n    command: npx\n    permission: yes-please\n",
             "mcp.fs.permission must be one of ask, auto, not \"yes-please\""},
            {"providers:\n  gw:\n    type: litellm\n",
             "providers.gw.type must be one of openai, anthropic, not \"litellm\"; a gateway that speaks the OpenAI API"}
          ] do
        File.write!(ctx.project, yaml)
        assert refused!(ctx) =~ expected, yaml
      end
    end

    test "was written for a newer Troupe", ctx do
      File.write!(ctx.user, "version: 2\nmodels:\n  default: x\n")
      assert refused!(ctx) =~ "#{ctx.user}:1: was written for a newer Troupe (version 2); this one reads version 1"
    end

    test "spells one setting two ways", ctx do
      File.write!(ctx.user, "model: a\nmodels:\n  default: b\n")
      assert refused!(ctx) =~ "model and models.default both set models.default; keep models.default and remove the other"

      File.write!(ctx.user, "small_model: a\nmodels:\n  small: b\n")
      assert refused!(ctx) =~ "set models.cheap; keep models.cheap"

      File.write!(ctx.user, "auth_token: t\nauth: api_key\n")
      assert refused!(ctx) =~ "auth_token means auth: bearer, and auth says \"api_key\""
    end
  end

  describe "a file that loads, and warns" do
    test "an unknown key names the file, the line, and the key it probably is", ctx do
      trust(ctx)

      File.write!(ctx.project, """
      max_tokns: 400000
      x-note: for another tool
      providers:
        gw:
          base_ur: https://gw.example/v1
      """)

      config = load!(ctx)
      assert config.max_tokens == 8192

      assert Enum.any?(
               config.warnings,
               &(&1 =~ "#{ctx.project}:1: max_tokns is not a setting Troupe knows, and is ignored; did you mean max_tokens?")
             )

      assert Enum.any?(config.warnings, &(&1 =~ "#{ctx.project}:5: providers.gw.base_ur is not a setting"))
      assert Enum.any?(config.warnings, &(&1 =~ "did you mean providers.gw.base_url?"))
      refute Enum.any?(config.warnings, &(&1 =~ "x-note"))
    end

    test "old spellings still work, each with a warning that names the new one", ctx do
      File.write!(ctx.user, """
      model: m-default
      small_model: m-cheap
      expensive_model: m-big
      windows: {m-default: 128000}
      auth_token: tok-1234567890
      """)

      config = load!(ctx)
      assert {config.model, config.small_model, config.expensive_model} == {"m-default", "m-cheap", "m-big"}
      assert config.windows == %{"m-default" => 128_000}
      assert {config.api_key, config.auth} == {"tok-1234567890", :bearer}
      assert length(config.warnings) == 5
      assert Enum.all?(config.warnings, &(&1 =~ "old spelling"))
    end

    test "auto_approve: no is off, and yes is on, each with a warning; never truthy", ctx do
      File.write!(ctx.user, "auto_approve: no\n")
      config = load!(ctx)
      assert config.auto_approve == false
      assert [warning] = config.warnings
      assert warning =~ "auto_approve: no is read as false; write false"

      File.write!(ctx.user, "auto_approve: yes\n")
      assert load!(ctx).auto_approve == true
    end

    test "the approval gate itself takes only true as on", _ctx do
      {:ok, gate} = Approvals.init(session_id: "no-log-#{System.unique_integer([:positive])}", auto_approve: "no")
      assert gate.auto_approve == false
    end

    test "mouse and llm_timeout_ms are settings of their own, not a catch-all", ctx do
      File.write!(ctx.user, "mouse: false\nllm_timeout_ms: 90000\n")
      config = load!(ctx)
      assert {config.mouse, config.llm_timeout_ms, config.warnings} == {false, 90_000, []}
    end
  end

  describe "merging" do
    test "a project that adds one provider keeps the user's other providers", ctx do
      trust(ctx, """
      providers:
        gateway:
          type: anthropic
          base_url: https://gw.example/anthropic/v1
          api_key: gw-key-1234567890
        portal:
          base_url: https://portal.example/v1
      """)

      File.write!(ctx.project, """
      providers:
        local:
          base_url: http://localhost:11434/v1
        portal:
          models: {glm: {context: 100000}}
      """)

      config = load!(ctx)
      assert Map.keys(config.providers) |> Enum.sort() == ["gateway", "local", "portal"]
      assert config.providers["gateway"].api_key == "gw-key-1234567890"
      # Merged key by key, down into the entry.
      assert config.providers["portal"].base_url == "https://portal.example/v1"
      assert config.providers["portal"].models["glm"].context == 100_000
    end

    test "null removes what a lower layer set, and a list replaces the list below it", ctx do
      trust(ctx, """
      read_roots: [/srv/a, /srv/b]
      providers:
        gateway: {base_url: https://gw.example/v1}
        other: {base_url: https://other.example/v1}
      models:
        default: gateway/x
        cheap: gateway/y
      """)

      File.write!(ctx.project, """
      read_roots: [/srv/c]
      providers:
        other: null
      models:
        cheap: null
      """)

      config = load!(ctx)
      assert config.read_roots == [Path.expand("/srv/c")]
      assert Map.keys(config.providers) == ["gateway"]
      assert {config.model, config.small_model} == {"gateway/x", nil}
    end

    test "config.local.yaml sits between the project's file and the environment", ctx do
      File.write!(ctx.user, "max_turns: 1\n")
      File.write!(ctx.project, "max_turns: 2\nmax_depth: 5\n")
      File.write!(Config.local_path(ctx.ws), "max_turns: 3\n")

      config = load!(ctx)
      assert {config.max_turns, config.max_depth} == {3, 5}
      # The command line beats every file.
      assert load!(ctx, max_turns: 4).max_turns == 4
    end
  end

  describe "an unset {env:VAR}" do
    test "refuses the provider that reads it, and never reaches a request", ctx do
      File.write!(ctx.user, """
      providers:
        gw:
          type: openai
          base_url: https://gw.example/v1
          api_key: "{env:TROUPE_TEST_SURELY_UNSET_1}"
        ok:
          type: openai
          base_url: https://ok.example/v1
          api_key: literal-key-1234567890
      """)

      {:ok, config, layers} = resolve(ctx)
      target = Config.target(config, "gw/some-model")
      assert {:refused, why} = target.api_key
      assert why =~ "providers.gw.api_key reads {env:TROUPE_TEST_SURELY_UNSET_1}"
      assert why =~ "TROUPE_TEST_SURELY_UNSET_1 is not set; the provider gw is refused"
      assert [%{level: :refusal}] = layers.refusals
      # The other provider is untouched, and the report says which one is refused.
      assert Config.target(config, "ok/m").api_key == "literal-key-1234567890"
      assert Config.describe(config) =~ "gw: openai https://gw.example/v1 key=(refused)"
    end

    test "in the session-wide key refuses the session-wide provider; opencode does not stand in", ctx do
      File.write!(ctx.user, "api_key: \"{env:TROUPE_TEST_SURELY_UNSET_2}\"\n")
      config = load!(ctx)
      assert {:refused, why} = Config.target(config, "claude-sonnet-5").api_key
      assert why =~ "the session-wide provider is refused"
      assert config.providers == %{}
    end

    test "refuses the MCP server that reads it, which is never started", ctx do
      File.write!(ctx.user, """
      mcp:
        wiki:
          command: wiki-mcp
          env: {TOKEN: "{env:TROUPE_TEST_SURELY_UNSET_3}"}
        fs:
          command: fs-mcp
      """)

      config = load!(ctx)
      assert config.mcp["wiki"].refused =~ "the MCP server wiki is not started"
      refute Map.has_key?(config.mcp["fs"], :refused)
    end

    test "anywhere else refuses the load", ctx do
      File.write!(ctx.user, "state_dir: \"{env:TROUPE_TEST_SURELY_UNSET_4}\"\n")
      assert refused!(ctx) =~ "state_dir reads {env:TROUPE_TEST_SURELY_UNSET_4}, and TROUPE_TEST_SURELY_UNSET_4 is not set"
    end

    test "is lifted by a later layer that sets the value", ctx do
      trust(ctx, "providers:\n  gw:\n    api_key: \"{env:TROUPE_TEST_SURELY_UNSET_5}\"\n")
      File.write!(Config.local_path(ctx.ws), "providers:\n  gw:\n    api_key: my-own-key-1234567890\n")
      assert Config.target(load!(ctx), "gw/m").api_key == "my-own-key-1234567890"
    end
  end

  describe "a workspace's own files" do
    setup ctx do
      File.write!(ctx.project, """
      auto_approve: true
      mcp:
        fs:
          command: fs-mcp
      base_url: https://elsewhere.example/v1
      read_roots: [/]
      max_turns: 7
      """)

      File.write!(Config.local_path(ctx.ws), "api_key: from-the-repository\n")
      :ok
    end

    test "set the gated keys only once the workspace is trusted, and say so until then", ctx do
      File.write!(ctx.user, "api_key: users-own-key-1234567890\n")
      config = load!(ctx)

      assert config.auto_approve == false
      assert config.mcp == %{}
      assert config.base_url == nil
      assert config.read_roots == []
      assert config.api_key == "users-own-key-1234567890"
      # What is not gated applies all the same.
      assert config.max_turns == 7

      assert Enum.any?(
               config.warnings,
               &(&1 =~
                   "#{ctx.project}: auto_approve, base_url, mcp and read_roots are ignored: " <>
                     "a project's file sets them only in a trusted workspace")
             )

      assert Enum.any?(config.warnings, &(&1 =~ "config.local.yaml: api_key is ignored: a project's file sets it only"))
      assert Enum.any?(
               config.warnings,
               &(&1 =~ "run `troupe config trust #{ctx.ws}`, which adds it to trusted_workspaces in #{ctx.user}")
             )

      trust(ctx)
      config = load!(ctx)
      assert config.auto_approve == true
      assert Map.keys(config.mcp) == ["fs"]
      assert config.base_url == "https://elsewhere.example/v1"
      assert config.api_key == "from-the-repository"
    end

    test "never set them on a pod, whatever the user file trusts", ctx do
      trust(ctx)
      config = load!(ctx, [], trust: :never)
      assert {config.auto_approve, config.mcp, config.base_url} == {false, %{}, nil}
      assert Enum.any?(config.warnings, &(&1 =~ "are ignored: a session on a pod never reads them from a project's file"))
    end

    test "are trusted by a directory above them", ctx do
      File.write!(ctx.user, "trusted_workspaces: [#{Jason.encode!(ctx.base)}]\n")
      assert load!(ctx).auto_approve == true
    end

    test "cannot trust themselves", ctx do
      File.write!(ctx.project, "trusted_workspaces: [#{Jason.encode!(ctx.ws)}]\nauto_approve: true\n")
      config = load!(ctx)
      assert config.auto_approve == false
      assert Enum.any?(config.warnings, &(&1 =~ "trusted_workspaces is ignored: it is read only from the user's config.yaml"))
    end
  end

  describe "trust" do
    test "a worktree of a trusted checkout is trusted, and a .git file cannot borrow it", ctx do
      main = Path.join(ctx.base, "main")
      admin = Path.join([main, ".git", "worktrees", "wt"])
      worktree = Path.join(ctx.base, "main-wt")
      File.mkdir_p!(admin)
      File.mkdir_p!(worktree)
      File.write!(Path.join(worktree, ".git"), "gitdir: #{admin}\n")
      File.write!(Path.join(admin, "gitdir"), Path.join(worktree, ".git") <> "\n")

      assert Trust.trusted?(worktree, [main])
      refute Trust.trusted?(worktree, [Path.join(ctx.base, "elsewhere")])

      impostor = Path.join(ctx.base, "impostor")
      File.mkdir_p!(impostor)
      File.write!(Path.join(impostor, ".git"), "gitdir: #{admin}\n")
      refute Trust.trusted?(impostor, [main])
    end

    test "a relative entry trusts nothing, and says so", ctx do
      File.write!(ctx.user, "trusted_workspaces: [ws]\n")
      File.write!(ctx.project, "auto_approve: true\n")
      config = load!(ctx)
      assert config.auto_approve == false
      assert Enum.any?(config.warnings, &(&1 =~ "\"ws\" is not an absolute path, and trusts nothing"))
    end
  end

  describe "the command line" do
    test "is checked like a file: a client's auto_approve must be true or false", ctx do
      assert {:error, error} = resolve(ctx, auto_approve: "no")
      assert Exception.message(error) =~ "auto_approve is set to \"no\"; it must be true or false"
      assert load!(ctx, auto_approve: true).auto_approve == true
    end
  end
end
