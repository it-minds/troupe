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
