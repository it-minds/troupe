defmodule Troupe.ReadRootsTest do
  @moduledoc """
  A quarter of the read-only shell calls in the session audit were the model
  routing around a refusal — `cd deps/ex_ratatui && sed -n ...` — because a read
  tool could not leave the workspace. These cover the widened read path and,
  just as importantly, that the write path did not widen with it.
  """
  use ExUnit.Case, async: true

  alias Troupe.Tool.Context
  alias Troupe.Tools.{EditFile, Grep, ListFiles, ReadFile, WriteFile}
  alias Troupe.Workspace

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-read-roots-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "ws")
    outside = Path.join(base, "vendor")

    File.mkdir_p!(Path.join(workspace, "lib"))
    File.mkdir_p!(Path.join(outside, "lib"))
    File.write!(Path.join(workspace, "lib/own.ex"), "defmodule Own do\n  @marker true\nend\n")
    File.write!(Path.join(outside, "lib/dep.ex"), "defmodule Dep do\n  @marker true\nend\n")

    on_exit(fn -> File.rm_rf(base) end)

    ctx = fn roots ->
      %Context{
        workspace: workspace,
        session_id: "s1",
        config: %Troupe.Config{read_roots: Enum.map(roots, &Path.expand/1)}
      }
    end

    {:ok, workspace: Path.expand(workspace), outside: Path.expand(outside), ctx: ctx}
  end

  describe "Workspace.resolve_readable/4" do
    test "still resolves paths inside the workspace", %{workspace: ws} do
      assert {:ok, abs} = Workspace.resolve_readable(ws, "lib/own.ex", [])
      assert abs == Path.join(ws, "lib/own.ex")
    end

    test "rejects an outside path when no read root allows it", %{workspace: ws, outside: out} do
      assert {:error, :outside_workspace} =
               Workspace.resolve_readable(ws, Path.join(out, "lib/dep.ex"), [])
    end

    test "allows an outside path under a read root", %{workspace: ws, outside: out} do
      assert {:ok, abs} = Workspace.resolve_readable(ws, Path.join(out, "lib/dep.ex"), [out])
      assert abs == Path.join(out, "lib/dep.ex")
    end

    test "a read root does not allow its siblings", %{workspace: ws, outside: out} do
      sibling = Path.join(Path.dirname(out), "elsewhere/secret.ex")
      assert {:error, :outside_workspace} = Workspace.resolve_readable(ws, sibling, [out])
    end

    test "judges a symlink by where it lands, not by its name", %{workspace: ws, outside: out} do
      # exactly the worktree case from the logs: `ln -s ../../../deps deps`
      link = Path.join(ws, "deps")
      :ok = File.ln_s(out, link)

      assert {:error, :outside_workspace} = Workspace.resolve_readable(ws, "deps/lib/dep.ex", [])
      assert {:ok, abs} = Workspace.resolve_readable(ws, "deps/lib/dep.ex", [out])
      assert abs == Path.join(out, "lib/dep.ex")
    end

    test "a null byte is still invalid, read root or not", %{workspace: ws, outside: out} do
      assert {:error, :invalid_path} = Workspace.resolve_readable(ws, "lib/\0.ex", [out])
    end
  end

  describe "read tools" do
    test "read_file reaches a read root and refuses without one", %{ctx: ctx, outside: out} do
      path = Path.join(out, "lib/dep.ex")

      assert {:error, msg} = ReadFile.run(%{"path" => path}, ctx.([]))
      assert msg =~ "escapes the workspace"

      assert {:ok, text} = ReadFile.run(%{"path" => path}, ctx.([out]))
      assert text =~ "defmodule Dep"
    end

    test "the refusal names the roots that were tried", %{ctx: ctx, outside: out} do
      assert {:error, msg} = ReadFile.run(%{"path" => "/etc/hostname"}, ctx.([out]))
      assert msg =~ "readable roots"
      assert msg =~ out
    end

    test "grep searches a read root", %{ctx: ctx, outside: out} do
      assert {:ok, hits} = Grep.run(%{"pattern" => "@marker", "path" => out}, ctx.([out]))
      assert hits =~ "dep.ex"

      assert {:error, msg} = Grep.run(%{"pattern" => "@marker", "path" => out}, ctx.([]))
      assert msg =~ "escapes the workspace"
    end

    test "list_files lists a read root relative to that root", %{ctx: ctx, outside: out} do
      assert {:ok, listing} = ListFiles.run(%{"path" => out, "pattern" => "**/*.ex"}, ctx.([out]))
      assert listing =~ "lib/dep.ex"
      refute listing =~ out
    end
  end

  describe "config" do
    test "read_roots is expanded, and junk entries are dropped" do
      ws = Path.join(System.tmp_dir!(), "troupe-rr-cfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(ws, ".troupe"))

      File.write!(
        Path.join([ws, ".troupe", "config.yaml"]),
        """
        read_roots:
          - ~/src/dep
          - ./relative
          - 42
        """
      )

      on_exit(fn -> File.rm_rf(ws) end)

      cfg = Troupe.Config.load(ws)

      assert Path.expand("~/src/dep") in cfg.read_roots
      assert Path.expand("./relative") in cfg.read_roots
      assert Enum.all?(cfg.read_roots, &is_binary/1)
      assert length(cfg.read_roots) == 2
    end

    test "defaults to none, which is the pre-existing confinement" do
      assert %Troupe.Config{}.read_roots == []
    end
  end

  describe "write tools stay confined" do
    test "write_file cannot write into a read root", %{ctx: ctx, outside: out} do
      target = Path.join(out, "lib/injected.ex")

      assert {:error, msg} = WriteFile.run(%{"path" => target, "content" => "boom"}, ctx.([out]))
      assert msg =~ "escapes the workspace"
      refute File.exists?(target)
    end

    test "edit_file cannot edit inside a read root", %{ctx: ctx, outside: out} do
      target = Path.join(out, "lib/dep.ex")

      assert {:error, msg} =
               EditFile.run(
                 %{
                   "path" => target,
                   "old_string" => "@marker true",
                   "new_string" => "@marker false"
                 },
                 ctx.([out])
               )

      assert msg =~ "escapes the workspace"
      assert File.read!(target) =~ "@marker true"
    end
  end
end
