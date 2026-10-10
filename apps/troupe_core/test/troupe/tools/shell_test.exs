defmodule Troupe.Tools.ShellTest do
  @moduledoc """
  Which bash the `shell` tool runs commands with on Windows (Decision 776): Git for
  Windows' own, or another on the `PATH`, never WSL's launcher, which would run them in a
  Linux distribution while the tool's description says Windows. Played with environments
  and file lists, so it runs on any host.
  """

  use ExUnit.Case, async: true

  alias Troupe.Tools.Shell

  defp exists(files), do: &(&1 in files)

  test "WSL's launcher first on the PATH is passed over for Git for Windows' bash" do
    env = %{
      "Path" =>
        "C:\\WINDOWS\\system32;C:\\Program Files\\Git\\cmd;C:\\Program Files\\Git\\usr\\bin",
      "SystemRoot" => "C:\\WINDOWS",
      "ProgramFiles" => "C:\\Program Files"
    }

    files = [
      "C:/WINDOWS/system32/bash.exe",
      "C:/Program Files/Git/cmd/git.exe",
      "C:/Program Files/Git/bin/bash.exe",
      "C:/Program Files/Git/usr/bin/bash.exe"
    ]

    assert Shell.windows_bash(env, exists(files)) == "C:/Program Files/Git/bin/bash.exe"
  end

  test "a Git installed anywhere is found from the git on the PATH" do
    env = %{
      "PATH" => "C:\\WINDOWS\\system32;D:\\tools\\PortableGit\\cmd",
      "SystemRoot" => "C:\\WINDOWS"
    }

    files = [
      "C:/WINDOWS/system32/bash.exe",
      "D:/tools/PortableGit/cmd/git.exe",
      "D:/tools/PortableGit/bin/bash.exe"
    ]

    assert Shell.windows_bash(env, exists(files)) == "D:/tools/PortableGit/bin/bash.exe"
  end

  test "with no Git, another bash on the PATH, and never WSL's or its app alias" do
    env = %{
      "PATH" =>
        "C:\\WINDOWS\\system32;C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps;C:\\msys64\\usr\\bin",
      "SystemRoot" => "C:\\WINDOWS"
    }

    wsl = [
      "C:/WINDOWS/system32/bash.exe",
      "C:/Users/me/AppData/Local/Microsoft/WindowsApps/bash.exe"
    ]

    assert Shell.windows_bash(env, exists(wsl ++ ["C:/msys64/usr/bin/bash.exe"])) ==
             "C:/msys64/usr/bin/bash.exe"

    # Only WSL's: no bash, and the tool falls back to PowerShell.
    assert Shell.windows_bash(env, exists(wsl)) == nil
  end

  test "Git installed for one user, where its installer puts it then" do
    env = %{"PATH" => "C:\\WINDOWS\\system32", "LOCALAPPDATA" => "C:\\Users\\me\\AppData\\Local"}

    files = [
      "C:/WINDOWS/system32/bash.exe",
      "C:/Users/me/AppData/Local/Programs/Git/bin/bash.exe"
    ]

    assert Shell.windows_bash(env, exists(files)) ==
             "C:/Users/me/AppData/Local/Programs/Git/bin/bash.exe"
  end
end

defmodule Troupe.Tools.ShellReleasePathTest do
  @moduledoc """
  A command the shell tool runs never has the release's own runtime on its `PATH`
  (Decision 776), whose `erl` has no boot file: the `elixir` a person's tests run with
  died at boot on it. `async: false`: it sets `RELEASE_ROOT` and `PATH`, which the whole
  VM reads.
  """

  use ExUnit.Case, async: false

  alias Troupe.Reaper
  alias Troupe.Tool.Ctx
  alias Troupe.Tools.Shell
  alias Troupe.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Map.new(~w(PATH RELEASE_ROOT), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "s-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{ctx: ctx}
  end

  test "outside a release the PATH is the VM's" do
    System.delete_env("RELEASE_ROOT")
    assert Reaper.child_env() == []
  end

  test "in a release, the runtime's bin is left out of a command's PATH", %{ctx: ctx} do
    if match?({:win32, _}, :os.type()), do: :ok, else: in_a_release(ctx)
  end

  defp in_a_release(ctx) do
    erts_bin =
      Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "bin"])

    System.put_env("RELEASE_ROOT", to_string(:code.root_dir()))
    System.put_env("PATH", erts_bin <> ":" <> System.get_env("PATH"))

    assert [{"PATH", path}] = Reaper.child_env()
    refute erts_bin in String.split(path, ":")

    assert {:ok, output, _outcome} = Shell.run(%{"command" => "echo \"$PATH\""}, ctx)
    refute erts_bin in (output |> String.trim() |> String.split(":"))
    assert output =~ "/usr/bin"
  end
end

defmodule Troupe.Tools.ShellLastLineTest do
  @moduledoc """
  The `shell` tool, and the runner a person's own command shares with it (Decision 813),
  answer with a last line that has no newline after it (#536): `printf x` answered
  "(no output)", because the port lets go of such a line only after the exit status.
  With the host's shell, so on Windows with Git for Windows' bash. `async: false`:
  `Troupe.ReaperTest` points the whole VM at a helper that will not start.
  """

  use ExUnit.Case, async: false

  alias Troupe.Tool.Ctx
  alias Troupe.Tools.Shell
  alias Troupe.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {:ok, workspace} = Workspace.new(root)

    ctx = %Ctx{
      session_id: "s-#{System.unique_integer([:positive])}",
      agent_path: ["root"],
      workspace: workspace,
      call_id: "call_1",
      agent_pid: self(),
      config: %Troupe.Config{}
    }

    %{ctx: ctx}
  end

  test "printf x answers x", %{ctx: ctx} do
    assert {:ok, "x", %{fields: %{"exit_status" => 0}}} =
             Shell.run(%{"command" => "printf x"}, ctx)

    assert {:ok, "x\n\n[exit status 3]", %{fields: %{"exit_status" => 3}}} =
             Shell.run(%{"command" => "printf x; exit 3"}, ctx)
  end

  test "cat reads a file without a final newline whole", %{ctx: ctx, tmp_dir: root} do
    File.write!(Path.join(root, "notes.txt"), "one\ntwo\nthree")
    assert {:ok, "one\ntwo\nthree", _outcome} = Shell.run(%{"command" => "cat notes.txt"}, ctx)
  end

  test "the runner streams the last line too", %{ctx: ctx} do
    me = self()

    assert {:ok, "one\ntwo", 0} =
             Shell.execute("printf 'one\\ntwo'", ctx.workspace,
               timeout_ms: 10_000,
               on_output: &send(me, {:streamed, &1})
             )

    assert streamed() == "one\ntwo"
  end

  defp streamed(acc \\ "") do
    receive do
      {:streamed, chunk} -> streamed(acc <> chunk)
    after
      0 -> acc
    end
  end
end
