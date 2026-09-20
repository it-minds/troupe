defmodule Troupe.Tools.ReadToolsTest do
  @moduledoc "`glob`, `git_read` and `web_fetch` (Decision 652): read-only, bounded, inside the workspace."

  use ExUnit.Case, async: true

  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{GitRead, Glob, WebFetch}
  alias Troupe.Workspace

  setup do
    root = Path.join(System.tmp_dir!(), "troupe-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "s-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{root: root, ctx: ctx}
  end

  describe "glob" do
    test "finds by pattern, newest first, and pages", %{root: root, ctx: ctx} do
      File.mkdir_p!(Path.join(root, "lib/deep"))
      File.write!(Path.join(root, "lib/a.ex"), "a")
      File.write!(Path.join(root, "lib/deep/b.ex"), "b")
      File.write!(Path.join(root, "lib/c.txt"), "c")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/x.ex"), "no")
      File.touch!(Path.join(root, "lib/a.ex"), System.os_time(:second) + 100)

      assert {:ok, out} = Glob.run(%{"pattern" => "**/*.ex"}, ctx)
      assert out == "lib/a.ex\nlib/deep/b.ex"

      assert {:ok, page} = Glob.run(%{"pattern" => "**/*.ex", "limit" => 1}, ctx)
      assert page =~ "lib/a.ex\n[… paths 2–2 of 2 omitted. Call glob(pattern: \"**/*.ex\", offset: 2, limit: 1)"

      assert {:ok, "no files match *.rs"} = Glob.run(%{"pattern" => "*.rs"}, ctx)
      assert {:ok, "lib/deep/b.ex"} = Glob.run(%{"pattern" => "*.ex", "path" => "lib/deep"}, ctx)
      assert {:error, {:outside_workspace, _}} = Glob.run(%{"pattern" => "*", "path" => "../.."}, ctx)
    end
  end

  describe "git_read" do
    setup %{root: root} do
      git!(root, ["init", "-q", "--initial-branch", "main"])
      git!(root, ["config", "user.email", "t@example.com"])
      git!(root, ["config", "user.name", "Troupe Test"])
      File.write!(Path.join(root, "README.md"), "# r\n")
      git!(root, ["add", "."])
      git!(root, ["commit", "-q", "-m", "first commit"])
      File.write!(Path.join(root, "README.md"), "# r\nchanged\n")
      :ok
    end

    test "status, diff, log, show and branch are read-only views", %{ctx: ctx} do
      assert {:ok, status} = GitRead.run(%{"op" => "status"}, ctx)
      assert status =~ "## main"
      assert status =~ " M README.md"

      assert {:ok, diff} = GitRead.run(%{"op" => "diff", "path" => "README.md"}, ctx)
      assert diff =~ "+changed"

      assert {:ok, log} = GitRead.run(%{"op" => "log", "limit" => 5}, ctx)
      assert log =~ "first commit"

      assert {:ok, show} = GitRead.run(%{"op" => "show"}, ctx)
      assert show =~ "first commit"
      assert show =~ "+# r"

      assert {:ok, branch} = GitRead.run(%{"op" => "branch"}, ctx)
      assert branch =~ "main"

      assert {:ok, "(no output)"} = GitRead.run(%{"op" => "diff", "staged" => true}, ctx)
    end

    test "flags cannot be smuggled in, and unknown ops are refused", %{ctx: ctx} do
      assert {:error, "ref may not start with `-`: --output=/tmp/x"} =
               GitRead.run(%{"op" => "log", "ref" => "--output=/tmp/x"}, ctx)

      assert {:error, "path may not start with `-`" <> _} =
               GitRead.run(%{"op" => "status", "path" => "-h"}, ctx)

      assert {:error, "unknown op: push" <> _} = GitRead.run(%{"op" => "push"}, ctx)
      assert {:error, "git exited " <> _} = GitRead.run(%{"op" => "show", "ref" => "nope"}, ctx)
    end
  end

  describe "web_fetch" do
    test "only absolute http(s) URLs are fetched, and an unreachable host is an error", %{ctx: ctx} do
      assert {:error, "url must be absolute" <> _} = WebFetch.run(%{"url" => "example.com"}, ctx)
      assert {:error, "web_fetch only speaks http and https, not ftp" <> _} = WebFetch.run(%{"url" => "ftp://x/y"}, ctx)

      {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)

      assert {:error, message} = WebFetch.run(%{"url" => "http://127.0.0.1:#{port}/"}, ctx)
      assert String.starts_with?(message, "GET http://127.0.0.1:#{port}/ failed: ")
    end

    test "HTML is reduced to readable text with links kept" do
      html = """
      <html><head><title>T</title><style>p{}</style></head>
      <body><h1>Hello &amp; welcome</h1><script>var x = 1;</script>
      <p>Read <a href="/docs">the docs</a> or <a href="https://x.test/">https://x.test/</a>.</p>
      <ul><li>one</li><li>two</li></ul></body></html>
      """

      text = WebFetch.to_text(html, "https://example.test/start")
      assert text =~ "# Hello & welcome"
      refute text =~ "var x"
      refute text =~ "p{}"
      assert text =~ "the docs (https://example.test/docs)"
      assert text =~ "https://x.test/."
      assert text =~ "- one\n- two"
    end
  end

  defp git!(cwd, args) do
    {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    :ok
  end
end
