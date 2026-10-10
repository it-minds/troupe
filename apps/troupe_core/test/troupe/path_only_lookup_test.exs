defmodule Troupe.PathOnlyLookupTest do
  @moduledoc """
  A program the daemon starts by name is the one on `PATH`, never one a repository carries
  (#555, Decision 846). The daemon runs here in the repository a TUI would have started it
  in: its current directory, and the directory its commands start in, both hold a planted
  `rg`, `git`, `bash`, an MCP server and a tool an `AGENTS.md` names, as does a relative
  entry of `PATH`, which is first on it (`.` and `rel`). Each planted program writes a
  marker when it runs; none may. On Windows `System.find_executable/1` looks in the current
  directory with no `.` on `PATH`, and the launcher in the directory a command starts in;
  `.` stands in for that here, which is the same lookup on Linux.

  `async: false`: it moves the VM's current directory and sets `PATH`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Instructions.Check
  alias Troupe.MCP.Stdio
  alias Troupe.{Reaper, Workspace}
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.{Grep, Shell}

  @moduletag timeout: 60_000

  @windows match?({:win32, _}, :os.type())
  @separator if @windows, do: ";", else: ":"
  @stub Path.expand("../support/mcp_stub.exs", __DIR__)

  # Outside this checkout, so no ignore file or repository of its own applies.
  setup do
    tmp = Path.join(System.tmp_dir!(), "troupe-path-only-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, "rel"))
    File.write!(Path.join(repo, "notes.txt"), "the needle\n")
    marker = Path.join(tmp, "planted-ran")

    path = System.get_env("PATH", "")
    System.put_env("PATH", Enum.join([".", "rel", path], @separator))
    on_exit(fn -> System.put_env("PATH", path) end)

    {:ok, workspace} = Workspace.new(repo)

    ctx = %Ctx{
      session_id: "path-only-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{tmp: tmp, repo: repo, marker: marker, ctx: ctx}
  end

  # The program `name` in the repository and its `rel/`, writing the marker if it runs.
  defp plant(%{repo: repo, marker: marker}, name) do
    for dir <- [repo, Path.join(repo, "rel")] do
      if @windows do
        File.write!(Path.join(dir, name <> ".bat"), "@echo #{name} >> \"#{marker}\"\r\n")
      else
        file = Path.join(dir, name)
        File.write!(file, "#!/bin/sh\necho #{name} >> '#{marker}'\n")
        File.chmod!(file, 0o755)
      end
    end
  end

  defp ran(%{marker: marker}), do: if(File.exists?(marker), do: File.read!(marker), else: "")

  test "grep runs ripgrep from the PATH or searches itself, never the repository's rg", context do
    plant(context, "rg")

    File.cd!(context.repo, fn ->
      assert {:ok, out} = Grep.run(%{"pattern" => "needle"}, context.ctx)
      assert out =~ "notes.txt:1:the needle"
    end)

    assert ran(context) == ""
  end

  test "Troupe's own git is the PATH's, not the one in the directory it runs in", context do
    plant(context, "git")

    File.cd!(context.repo, fn ->
      assert {:ok, "git version" <> _, 0} = Reaper.run(context.repo, ["git", "--version"])
    end)

    assert ran(context) == ""
  end

  test "the shell is the PATH's, and runs the command", context do
    plant(context, if(@windows, do: "pwsh", else: "bash"))

    File.cd!(context.repo, fn ->
      {shell, _flag} = Shell.shell()
      refute String.starts_with?(Path.expand(shell), Path.expand(context.repo))
      assert {:ok, out, _fields} = Shell.run(%{"command" => "echo hi"}, context.ctx)
      assert out =~ "hi"
    end)

    assert ran(context) == ""
  end

  test "an MCP server named by a name on no PATH is refused, and the planted one never runs",
       context do
    plant(context, "troupe-planted-mcp")

    File.cd!(context.repo, fn ->
      assert %{state: :error, error: error} =
               Stdio.probe("planted", %{"command" => "troupe-planted-mcp"}, context.repo, 3_000)

      assert error == "could not start: `troupe-planted-mcp` is not on the PATH"
    end)

    assert ran(context) == ""
  end

  test "a command an AGENTS.md names is looked for on the PATH alone", context do
    plant(context, "troupe-planted-tool")
    File.mkdir_p!(Path.join(context.repo, ".git"))

    File.write!(
      Path.join(context.repo, "AGENTS.md"),
      "# Build\n\n```sh\ntroupe-planted-tool build\n```\n"
    )

    File.cd!(context.repo, fn ->
      %{root: root, sources: sources, elsewhere?: elsewhere?} = Check.sources(context.repo)

      assert [%{kind: :command, message: message}] =
               Check.findings(sources, root: root, elsewhere?: elsewhere?)

      assert message == "`troupe-planted-tool` is not on the PATH (`troupe-planted-tool build`)"
    end)

    assert ran(context) == ""
  end

  # A command given as a path keeps working as written, from the workspace rather than
  # from wherever the daemon was started.
  @tag skip: @windows && "a shell script as the server"
  test "an MCP server given by a relative path is the workspace's", %{tmp: tmp} = context do
    elixir = System.find_executable("elixir")
    server = Path.join([context.repo, "bin", "server"])
    File.mkdir_p!(Path.dirname(server))
    File.write!(server, "#!/bin/sh\nexec '#{elixir}' '#{@stub}'\n")
    File.chmod!(server, 0o755)

    File.cd!(tmp, fn ->
      assert %{state: :ready, tools: ["greet"]} =
               Stdio.probe("relative", %{"command" => "bin/server"}, context.repo, 20_000)
    end)
  end
end
