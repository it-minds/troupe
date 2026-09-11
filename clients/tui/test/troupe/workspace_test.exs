defmodule Troupe.WorkspaceTest do
  use ExUnit.Case, async: true

  import Troupe.TestHelpers

  alias Troupe.Workspace

  # Done item 9 (unix)
  test "rejects ../ escapes and symlinks pointing outside the workspace" do
    ws = tmp_workspace(%{"inside.txt" => "ok"})
    outside = tmp_workspace(%{"secret.txt" => "no"})
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(ws, "link.txt"))
    File.ln_s!(outside, Path.join(ws, "linkdir"))

    assert {:ok, _} = Workspace.resolve(ws, "inside.txt")
    assert {:ok, _} = Workspace.resolve(ws, "new/dir/file.txt")
    assert {:error, :outside_workspace} = Workspace.resolve(ws, "../../etc/passwd")
    assert {:error, :outside_workspace} = Workspace.resolve(ws, "/etc/passwd")
    assert {:error, :outside_workspace} = Workspace.resolve(ws, "link.txt")
    assert {:error, :outside_workspace} = Workspace.resolve(ws, "linkdir/secret.txt")
    assert {:error, :invalid_path} = Workspace.resolve(ws, "a\0b")
  end

  # Done item 9 (windows path rules, pure)
  test "windows: backslash escapes, other drives, UNC, junctions and case variants are rejected" do
    root = "C:\\Users\\dev\\proj"
    id = fn p -> p end
    opts = [os: :windows, canonicalize: id]

    assert {:ok, "C:/Users/dev/proj/lib/a.ex"} = Workspace.resolve(root, "lib\\a.ex", opts)
    assert {:error, :outside_workspace} = Workspace.resolve(root, "..\\..\\Windows\\System32", opts)
    assert {:error, :outside_workspace} = Workspace.resolve(root, "D:\\other\\file", opts)
    assert {:error, :outside_workspace} = Workspace.resolve(root, "\\\\server\\share\\x", opts)
    assert {:error, :outside_workspace} = Workspace.resolve(root, "\\Windows\\System32", opts)
    assert {:error, :invalid_path} = Workspace.resolve(root, "D:relative", opts)

    # a junction inside the workspace pointing outside: canonicalize resolves it
    junction = fn
      "C:/Users/dev/proj/junc" <> rest -> "D:/elsewhere" <> rest
      p -> p
    end

    assert {:error, :outside_workspace} =
             Workspace.resolve(root, "junc\\x.txt", os: :windows, canonicalize: junction)

    # case variants of the workspace path are the same workspace, not an escape
    assert {:ok, _} = Workspace.resolve(root, "c:\\users\\DEV\\proj\\lib\\a.ex", opts)
    assert {:ok, _} = Workspace.resolve(root, "C:\\Users\\dev\\proj\\..\\proj\\lib\\a.ex", opts)

    assert {:error, :outside_workspace} =
             Workspace.resolve(root, "C:\\Users\\dev\\proj2\\a.ex", opts)

    assert {:error, :outside_workspace} =
             Workspace.resolve(root, "c:\\users\\DEV\\..\\admin\\x", opts)
  end
end
