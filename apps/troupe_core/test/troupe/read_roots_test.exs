defmodule Troupe.ReadRootsTest do
  @moduledoc """
  The widened read path (Decision 653), and — just as importantly — that the write path
  did not widen with it.
  """

  use ExUnit.Case, async: true

  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{EditFile, Glob, Grep, ListFiles, ReadFile, WriteFile}
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

    {:ok, ws} = Workspace.new(workspace)

    ctx = fn roots ->
      %Ctx{
        session_id: "s1",
        agent_path: ["root"],
        workspace: ws,
        call_id: "c1",
        agent_pid: self(),
        config: %Troupe.Config{read_roots: Enum.map(roots, &Path.expand/1)}
      }
    end

    %{ws: ws, outside: Path.expand(outside), ctx: ctx}
  end

  describe "Workspace.resolve_readable/3" do
    test "still resolves paths inside the workspace", %{ws: ws} do
      assert {:ok, abs} = Workspace.resolve_readable(ws, "lib/own.ex", [])
      assert abs == Path.join(ws.root_real, "lib/own.ex")
    end

    test "rejects an outside path when no read root allows it", %{ws: ws, outside: out} do
      assert {:error, {:outside_workspace, _}} =
               Workspace.resolve_readable(ws, Path.join(out, "lib/dep.ex"), [])
    end

    test "allows an outside path under a read root, not its siblings", %{ws: ws, outside: out} do
      assert {:ok, abs} = Workspace.resolve_readable(ws, Path.join(out, "lib/dep.ex"), [out])
      assert Path.basename(abs) == "dep.ex"

      sibling = Path.join(Path.dirname(out), "elsewhere/secret.ex")
      assert {:error, {:outside_workspace, _}} = Workspace.resolve_readable(ws, sibling, [out])
    end

    test "judges a symlink by where it lands, not by its name", %{ws: ws, outside: out} do
      link = Path.join(ws.root_real, "deps")
      :ok = File.ln_s(out, link)

      assert {:error, {:outside_workspace, _}} = Workspace.resolve_readable(ws, "deps/lib/dep.ex", [])
      assert {:ok, abs} = Workspace.resolve_readable(ws, "deps/lib/dep.ex", [out])
      assert Path.basename(abs) == "dep.ex"
      assert File.read!(abs) =~ "Dep"
    end
  end

  describe "the tools" do
    test "read_file, list_files, grep and glob reach a read root and refuse without one",
         %{ctx: ctx, outside: out} do
      path = Path.join(out, "lib/dep.ex")

      assert {:error, {:outside_workspace, _}} = ReadFile.run(%{"path" => path}, ctx.([]))
      assert {:ok, text} = ReadFile.run(%{"path" => path}, ctx.([out]))
      assert text =~ "defmodule Dep"

      assert {:error, {:outside_workspace, _}} = ListFiles.run(%{"path" => out}, ctx.([]))
      assert {:ok, listed} = ListFiles.run(%{"path" => out, "pattern" => "**/*.ex"}, ctx.([out]))
      assert listed =~ "dep.ex"

      assert {:ok, found} = Grep.run(%{"pattern" => "@marker", "path" => out}, ctx.([out]))
      assert found =~ "dep.ex"

      assert {:ok, globbed} = Glob.run(%{"pattern" => "**/*.ex", "path" => out}, ctx.([out]))
      assert globbed =~ "dep.ex"
    end

    test "the write tools never leave the workspace, read root or not", %{ctx: ctx, outside: out} do
      path = Path.join(out, "lib/dep.ex")

      assert {:error, {:outside_workspace, _}} =
               WriteFile.run(%{"path" => path, "content" => "x"}, ctx.([out]))

      assert {:error, {:outside_workspace, _}} =
               EditFile.run(%{"path" => path, "old_string" => "Dep", "new_string" => "X"}, ctx.([out]))

      assert File.read!(path) =~ "defmodule Dep"
    end

    test "read_roots in a config file are expanded" do
      dir = Path.join(System.tmp_dir!(), "troupe-rr-cfg-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dir, ".troupe"))
      on_exit(fn -> File.rm_rf(dir) end)
      File.write!(Path.join(dir, ".troupe/config.yaml"), "read_roots:\n  - ../vendor\n  - 7\n")

      config = Troupe.Config.load(dir)
      assert config.read_roots == [Path.expand("../vendor")]
    end
  end
end
