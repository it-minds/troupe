defmodule Troupe.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Troupe.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "src"))
    File.write!(Path.join(root, "src/a.ex"), "hello")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, ws} = Workspace.new(root)
    %{root: root, ws: ws}
  end

  test "resolves a relative path inside the workspace", %{ws: ws, root: root} do
    {:ok, real_root} = Workspace.real_path(root)
    assert {:ok, resolved} = Workspace.resolve(ws, "src/a.ex")
    assert resolved == Path.join(real_root, "src/a.ex")
  end

  test "resolves a path to a file that does not exist yet", %{ws: ws} do
    assert {:ok, resolved} = Workspace.resolve(ws, "src/new/deep/file.ex")
    assert String.ends_with?(resolved, "src/new/deep/file.ex")
  end

  test "rejects ../../etc/passwd", %{ws: ws} do
    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "../../etc/passwd")
  end

  test "rejects an absolute path outside", %{ws: ws} do
    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "/etc/passwd")
  end

  test "rejects a symlink pointing outside", %{ws: ws, root: root} do
    outside = Path.join(System.tmp_dir!(), "troupe-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "s3cret")
    on_exit(fn -> File.rm_rf!(outside) end)

    File.ln_s!(outside, Path.join(root, "escape"))

    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "escape/secret")
    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "escape")
  end

  test "allows a symlink that stays inside", %{ws: ws, root: root} do
    File.ln_s!(Path.join(root, "src"), Path.join(root, "link"))
    assert {:ok, resolved} = Workspace.resolve(ws, "link/a.ex")
    assert String.ends_with?(resolved, "src/a.ex")
  end

  test "rejects a path that walks out through a symlink", %{ws: ws, root: root} do
    parent = Path.dirname(root)
    File.ln_s!(parent, Path.join(root, "up"))
    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "up/anything")
  end

  test "resolves .. that stays inside", %{ws: ws} do
    assert {:ok, resolved} = Workspace.resolve(ws, "src/../src/a.ex")
    assert String.ends_with?(resolved, "src/a.ex")
  end

  test "a sibling sharing the root's prefix is outside", %{ws: ws, root: root} do
    sibling = root <> "-evil"
    File.mkdir_p!(sibling)
    on_exit(fn -> File.rm_rf!(sibling) end)
    assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, sibling)
  end

  test "detects a symlink loop instead of hanging", %{root: root} do
    File.ln_s!(Path.join(root, "loop_b"), Path.join(root, "loop_a"))
    File.ln_s!(Path.join(root, "loop_a"), Path.join(root, "loop_b"))
    assert {:error, :symlink_loop} = Workspace.real_path(Path.join(root, "loop_a"))
  end

  describe "windows-shaped paths" do
    # These run everywhere: the parsing they exercise is pure string work, and a
    # drive letter or UNC share must be a distinct root on every host so a
    # Windows-shaped escape can never be mistaken for a relative path.
    test "a drive-letter path is absolute and rooted at the drive", %{ws: ws} do
      assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "C:\\Windows\\System32")
      assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "D:/data")
    end

    test "a UNC path is absolute and rooted at the share", %{ws: ws} do
      assert {:error, {:outside_workspace, _}} = Workspace.resolve(ws, "\\\\server\\share\\x")
    end

    test "backslash traversal is rejected", %{ws: ws} do
      assert {:error, {:outside_workspace, _}} =
               Workspace.resolve(ws, "..\\..\\Windows\\System32")
    end

    test "a case variant of the workspace does not escape it on Windows" do
      # On Windows the comparison is case-insensitive, so `C:/Repo` and `c:/repo` are
      # the same place and a case-variant cannot be used to slip outside a workspace.
      # Checking the comparison form directly is what makes this testable from a host
      # that is not Windows.
      assert Workspace.compare_key("C:\\Repo\\Lib", :windows) ==
               Workspace.compare_key("c:/repo/lib", :windows)

      assert Workspace.compare_key("C:\\Repo\\", :windows) == "c:/repo"
    end

    test "separators are equivalent under the Windows rules" do
      assert Workspace.compare_key("C:\\a\\b", :windows) ==
               Workspace.compare_key("C:/a/b", :windows)
    end

    test "case is significant everywhere else" do
      refute Workspace.compare_key("/Repo/Lib", :unix) ==
               Workspace.compare_key("/repo/lib", :unix)
    end
  end
end
