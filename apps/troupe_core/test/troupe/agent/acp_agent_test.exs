defmodule Troupe.Agent.ACPAgentTest do
  @moduledoc """
  A third-party ACP agent, served through the mount table rather than the disk.

  This is the claim that makes running somebody else's agent inside a session defensible,
  and it is a narrow one: **the refusal an ACP agent gets is the refusal a tool gets**.
  Not a check written in the ACP layer that happens to agree with the tool layer — the same
  `Mounts.resolve/3`, so the two cannot drift apart and a mount added later applies without
  anybody remembering to apply it here.

  The tests are therefore mostly about paths: which ones resolve, which ones do not, and
  whether a read-only mount is read-only to a subprocess as well as to a model.
  """

  use ExUnit.Case, async: true

  alias Troupe.Agent.ACPAgent
  alias Troupe.{Mounts, Workspace}

  @moduletag timeout: 30_000

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-acp-#{System.unique_integer([:positive])}")
    session_root = Path.join(base, "session")
    org = Path.join(base, "org")
    outside = Path.join(base, "outside")

    for dir <- [session_root, org, outside], do: File.mkdir_p!(dir)
    File.write!(Path.join(session_root, "notes.md"), "one\ntwo\nthree\nfour\n")
    File.write!(Path.join(org, "handbook.md"), "how we work")
    File.write!(Path.join(outside, "secret.txt"), "not yours")

    on_exit(fn -> File.rm_rf!(base) end)

    mounts =
      Mounts.new([
        %{name: "session", kind: :session, root: session_root, mode: :rw},
        # Read-only on purpose: the interesting question is not whether an agent can be kept
        # out, but whether a mount it *can* see keeps its mode.
        %{name: "org", kind: :org, root: org, mode: :ro}
      ])

    workspace = %{Workspace.new!(session_root) | mounts: mounts}

    %{workspace: workspace, base: base, session_root: session_root, outside: outside}
  end

  describe "reading" do
    test "resolves through the mounts, like every other path in a session", context do
      assert {:ok, %{"content" => content}} =
               ACPAgent.serve("fs/read_text_file", %{"path" => "notes.md"}, context.workspace)

      assert content =~ "one"

      # And a named mount is reached by its name, which is the only way anything reaches one.
      assert {:ok, %{"content" => "how we work"}} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "org:handbook.md"},
                 context.workspace
               )
    end

    test "takes the window ACP asked for", context do
      assert {:ok, %{"content" => content}} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "notes.md", "line" => 2, "limit" => 2},
                 context.workspace
               )

      assert content == "two\nthree"
    end

    test "a path outside the mounts fails the way any other tool call does", context do
      # Done item 2. Not a check written here: `Workspace.resolve/3` refused it, which is
      # the same call `write_file` and `read_file` make.
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => Path.join(context.outside, "secret.txt")},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
      assert error["data"]["path"] =~ "secret.txt"
    end

    test "and so does climbing out of one", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/read_text_file",
                 %{"path" => "../outside/secret.txt"},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
    end
  end

  describe "writing" do
    test "lands inside the session's own root", context do
      assert {:ok, %{}} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => "written.txt", "content" => "by the agent"},
                 context.workspace
               )

      assert File.read!(Path.join(context.session_root, "written.txt")) == "by the agent"
    end

    test "is refused by a read-only mount, and the refusal names it", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => "org:handbook.md", "content" => "rewritten"},
                 context.workspace
               )

      # Named, because an agent told *read-only* can choose somewhere else where one told
      # *denied* can only retry. And the mode came from the mount table rather than from a
      # rule this module keeps in step with it.
      assert error["message"] =~ "read-only"
      assert error["data"]["mount"] == "org"
      assert File.read!(Path.join(context.base, "org/handbook.md")) == "how we work"
    end

    test "cannot reach outside the mounts at all", context do
      assert {:error, error} =
               ACPAgent.serve(
                 "fs/write_text_file",
                 %{"path" => Path.join(context.outside, "planted.txt"), "content" => "x"},
                 context.workspace
               )

      assert error["message"] =~ "not in this session's mounts"
      refute File.exists?(Path.join(context.outside, "planted.txt"))
    end
  end

  describe "the terminal" do
    test "is refused, and says why rather than reporting a missing capability", context do
      # A session's shell is approved, budgeted and logged. Handing an ACP agent an
      # unmediated one would be a way round all three, so it is not offered — and the
      # handshake says so, which is the difference between a refusal and a surprise.
      assert ACPAgent.client_capabilities()["terminal"] == false

      assert {:error, error} =
               ACPAgent.serve(
                 "terminal/create",
                 %{"command" => "curl", "args" => ["https://example.com"]},
                 context.workspace
               )

      assert error["data"]["reason"] =~ "approved, budgeted and logged"
    end
  end

  describe "a method nobody implements" do
    test "is method_not_found, not silence", context do
      assert {:error, %{"code" => -32_601}} =
               ACPAgent.serve("session/request_permission", %{}, context.workspace)
    end
  end
end
