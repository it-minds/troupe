defmodule Troupe.Daemon.ReleaseTest do
  @moduledoc """
  What the release steps write, as far as text can prove it: the Windows wrapper's `run
  --detached`, which the login entry relies on, and `detached.vm.args` derived from
  `vm.args`. The scripts are not run here; the Windows release job runs them.
  """

  use ExUnit.Case, async: true

  alias Troupe.Daemon.Release

  test "detached.vm.args is vm.args with -detached after it, and nothing of it dropped" do
    vm_args = "## Windows\n-noinput\n+Bc\n"
    text = Release.detached_vm_args(vm_args)

    assert String.starts_with?(text, "## Windows\n-noinput\n+Bc\n")
    assert String.ends_with?(text, "\n-detached\n")
    assert length(Regex.scan(~r/^-detached$/m, text)) == 1
  end

  test "the Windows wrapper's run takes --detached, hands it to start, and refuses anything else" do
    cmd = Release.wrapper_cmd()

    assert cmd =~ ~S|if "%~2"=="--detached" set "detached=--detached"|
    assert cmd =~ ~S|call "%rel%" start %detached% <nul|
    assert cmd =~ "troupe-daemon run takes --detached and nothing else"
    # Only `start` is ever detached: a `status` or `login` run that way would answer nothing.
    refute cmd =~ ~r/eval .*detached/
    # Every VM it starts reads the null device, so Ctrl-C stays a signal under +Bc.
    assert Regex.scan(~r/call "%rel%"/, cmd) |> length() ==
             Regex.scan(~r/call "%rel%".*<nul/, cmd) |> length()
  end
end
