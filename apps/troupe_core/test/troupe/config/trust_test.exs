defmodule Troupe.Config.TrustTest do
  @moduledoc """
  `troupe config trust`, `untrust` and `trust --list` (#161): what they write into the
  user file, that the rest of the file survives them, how a git worktree resolves to its
  checkout, and that a project file's gated key follows the list both ways.

  Every test has a user file of its own (`user_path:`), so the suite's shared config
  directory, which trusts the temp directory, is not what decides these.
  """

  use ExUnit.Case, async: true

  alias Troupe.Config
  alias Troupe.Config.Trust

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-trust-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "ws")
    File.mkdir_p!(Path.join(ws, ".troupe"))
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base, ws: ws, user: Path.join(base, "config.yaml")}
  end

  defp trust(ctx, path \\ nil), do: Trust.trust(path || ctx.ws, user_path: ctx.user)
  defp untrust(ctx, path \\ nil), do: Trust.untrust(path || ctx.ws, user_path: ctx.user)

  defp entries(ctx) do
    {:ok, map} = YamlElixir.read_from_file(ctx.user)
    map["trusted_workspaces"]
  end

  @user_file """
  # my own settings
  models:
    default: gateway/glm-5.2   # the one I use

  trusted_workspaces:
    - ~/src/elsewhere   # a comment on an entry

  # budgets
  max_turns: 40
  """

  test "trust adds the workspace and keeps the file's comments, its other keys and a copy as it was", ctx do
    File.write!(ctx.user, @user_file)

    assert {text, 0} = trust(ctx)
    assert text =~ "trusted #{ctx.ws}"
    assert text =~ "the file as it was is #{ctx.user}.previous"

    assert File.read!(ctx.user) ==
             String.replace(@user_file, "a comment on an entry\n", "a comment on an entry\n  - #{Jason.encode!(ctx.ws)}\n")

    assert File.read!(ctx.user <> ".previous") == @user_file
  end

  test "untrust removes it again, and the file is what it was before trust", ctx do
    File.write!(ctx.user, @user_file)
    {_text, 0} = trust(ctx)

    assert {text, 0} = untrust(ctx)
    assert text =~ "untrusted #{ctx.ws}"
    assert text =~ "removed #{ctx.ws} from trusted_workspaces"
    assert File.read!(ctx.user) == @user_file
  end

  test "a project file's gated key applies after trust, and is ignored again after untrust", ctx do
    File.write!(ctx.user, @user_file)
    project = Config.project_path(ctx.ws)
    File.write!(project, "provider: fake\nmax_turns: 7\n")

    {:ok, config, _layers} = Config.resolve(ctx.ws, [], user_path: ctx.user)
    refute to_string(config.provider) == "fake"
    assert config.max_turns == 7

    assert Enum.any?(
             config.warnings,
             &(&1 =~ "provider is ignored" and &1 =~ "run `troupe config trust #{ctx.ws}`, which adds it to trusted_workspaces")
           )

    {explained, 0} = Config.explain(ctx.ws, "provider", user_path: ctx.user)
    assert explained =~ "(not trusted: its files set no key marked trusted; `troupe config trust` trusts it)"
    assert explained =~ "ignored: a project's file sets it only in a trusted workspace. To trust this one, run"

    {_text, 0} = trust(ctx)
    {:ok, config, _layers} = Config.resolve(ctx.ws, [], user_path: ctx.user)
    assert to_string(config.provider) == "fake"
    refute Enum.any?(config.warnings, &(&1 =~ "troupe config trust"))

    {explained, 0} = Config.explain(ctx.ws, "provider", user_path: ctx.user)
    assert explained =~ ~r/project\s+"?fake"?\s+#{Regex.escape(project)}\s+<- in effect/

    {_text, 0} = untrust(ctx)
    {:ok, config, _layers} = Config.resolve(ctx.ws, [], user_path: ctx.user)
    refute to_string(config.provider) == "fake"
    assert Enum.any?(config.warnings, &(&1 =~ "run `troupe config trust #{ctx.ws}`"))
  end

  test "a workspace already trusted, by itself or by a directory above it, is not added again", ctx do
    File.write!(ctx.user, "trusted_workspaces:\n  - #{Jason.encode!(ctx.base)}\n")

    assert {text, 0} = trust(ctx)
    assert text =~ "#{ctx.ws} is already trusted: trusted_workspaces in #{ctx.user} has #{ctx.base}"
    assert entries(ctx) == [ctx.base]
    refute File.exists?(ctx.user <> ".previous")
  end

  test "untrust leaves an entry for a directory above, and says it still trusts the workspace", ctx do
    File.write!(ctx.user, "trusted_workspaces:\n  - #{Jason.encode!(ctx.base)}\n  - #{Jason.encode!(ctx.ws)}\n")

    assert {text, 1} = untrust(ctx)
    assert text =~ "removed #{ctx.ws}"
    assert text =~ "#{ctx.ws} is still trusted: trusted_workspaces in #{ctx.user} has #{ctx.base}"
    assert text =~ "`troupe config untrust #{ctx.base}` removes that"
    assert entries(ctx) == [ctx.base]
  end

  test "untrust of a workspace nothing trusts writes nothing", ctx do
    File.write!(ctx.user, @user_file)

    assert {text, 0} = untrust(ctx)
    assert text =~ "#{ctx.ws} is not trusted"
    assert File.read!(ctx.user) == @user_file
    refute File.exists?(ctx.user <> ".previous")
  end

  test "with no user file, trust writes one the loader reads", ctx do
    assert {text, 0} = trust(ctx)
    refute text =~ ".previous"
    assert entries(ctx) == [ctx.ws]
    assert File.read!(ctx.user) =~ "version: 1\n"
    assert Trust.trusted?(ctx.ws, entries(ctx))
  end

  describe "a git worktree" do
    setup ctx do
      main = Path.join(ctx.base, "main")
      admin = Path.join([main, ".git", "worktrees", "wt"])
      worktree = Path.join(ctx.base, "main-wt")
      File.mkdir_p!(admin)
      File.mkdir_p!(worktree)
      File.write!(Path.join(worktree, ".git"), "gitdir: #{admin}\n")
      File.write!(Path.join(admin, "gitdir"), Path.join(worktree, ".git") <> "\n")
      %{main: main, worktree: worktree}
    end

    test "trust in a worktree writes its checkout, which trusts the worktree and the checkout", ctx do
      assert Trust.root(ctx.worktree) == ctx.main

      assert {text, 0} = trust(ctx, ctx.worktree)
      assert text =~ "#{ctx.worktree} is a git worktree of #{ctx.main}"
      assert entries(ctx) == [ctx.main]
      assert Trust.trusted?(ctx.worktree, entries(ctx))
      assert Trust.trusted?(ctx.main, entries(ctx))
    end

    test "untrust in a worktree removes the checkout's entry", ctx do
      {_text, 0} = trust(ctx, ctx.main)

      assert {_text, 0} = untrust(ctx, ctx.worktree)
      assert entries(ctx) == []
      refute Trust.trusted?(ctx.worktree, entries(ctx))
    end

    test "a directory that only claims to be a worktree resolves to itself", ctx do
      impostor = Path.join(ctx.base, "impostor")
      File.mkdir_p!(impostor)
      File.write!(Path.join(impostor, ".git"), "gitdir: #{Path.join([ctx.main, ".git", "worktrees", "wt"])}\n")

      assert Trust.root(impostor) == impostor
    end
  end

  test "trust refuses what is not a directory, and a user file it cannot read as YAML, writing nothing", ctx do
    assert {text, 1} = trust(ctx, Path.join(ctx.base, "nowhere"))
    assert text =~ "is not a directory"
    refute File.exists?(ctx.user)

    File.write!(ctx.user, "models:\n  default: x\n    cheap: [unclosed\n")
    assert {text, 1} = trust(ctx)
    assert text =~ "is not valid YAML"
    assert File.read!(ctx.user) == "models:\n  default: x\n    cheap: [unclosed\n"

    File.write!(ctx.user, "trusted_workspaces: /one/path\n")
    assert {text, 1} = trust(ctx)
    assert text =~ "trusted_workspaces must be a list of paths"
  end

  test "a file written in a shape the edit does not follow is left as it was, with what to add by hand", ctx do
    File.write!(ctx.user, "{max_turns: 3, trusted_workspaces: []}\n")

    assert {text, 1} = trust(ctx)
    assert text =~ "so it is as it was; add #{Jason.encode!(ctx.ws)} to trusted_workspaces"
    assert File.read!(ctx.user) == "{max_turns: 3, trusted_workspaces: []}\n"
  end

  test "--list shows the entries as written, a relative one marked as trusting nothing", ctx do
    assert {"no workspace is trusted: " <> _, 0} = Trust.list(user_path: ctx.user)

    File.write!(ctx.user, "trusted_workspaces:\n  - ~/src/work\n  - relative/dir\n")
    assert {text, 0} = Trust.list(user_path: ctx.user)
    assert text == "trusted_workspaces in #{ctx.user}:\n  ~/src/work\n  relative/dir  (not an absolute path, and trusts nothing)\n"
  end

  test "the command a warning names quotes a path with a space in it" do
    assert Trust.command("/src/my repo") == ~s(troupe config trust "/src/my repo")
    assert Trust.command("/src/repo") == "troupe config trust /src/repo"
  end
end
