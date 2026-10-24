defmodule Troupe.Release.OSSigningTest do
  use ExUnit.Case, async: true

  alias Troupe.Release.OSSigning

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-os-signing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "release/bin"))
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  # A stand-in for scripts/signing/sign-macos.sh: it writes down the directory it was
  # handed, and exits with what the test asks.
  defp signer(dir, status) do
    path = Path.join(dir, "signer-#{status}.sh")
    File.write!(path, "printf '%s\\n' \"$1\" >> \"#{dir}/signed\"\nexit #{status}\n")
    path
  end

  test "without a signer nothing runs, and the release is what it was", %{dir: dir} do
    release = %Mix.Release{path: Path.join(dir, "release")}
    assert OSSigning.sign!(release.path, nil) == :unsigned
    assert OSSigning.sign!(release.path, "") == :unsigned
    refute File.exists?(Path.join(dir, "signed"))
  end

  test "the signer is handed the release's directory before it is packed", %{dir: dir} do
    target = Path.join(dir, "release")
    assert OSSigning.sign!(target, signer(dir, 0)) == :signed
    assert File.read!(Path.join(dir, "signed")) == target <> "\n"
  end

  test "a signer that fails stops the build", %{dir: dir} do
    assert_raise Mix.Error, ~r/exited 3/, fn ->
      OSSigning.sign!(Path.join(dir, "release"), signer(dir, 3))
    end
  end

  test "a Burrito step: the payload's directory, and the context back unchanged", %{dir: dir} do
    context = %{work_dir: Path.join(dir, "release"), halted: false}
    # TROUPE_SIGN is not set in the test environment, so the step is the no-op every
    # unsigned build runs.
    assert OSSigning.execute(context) == context
    refute File.exists?(Path.join(dir, "signed"))
  end

  test "a PowerShell signer runs under PowerShell, a shell script under sh" do
    assert {"sh", ["scripts/signing/sign-macos.sh", "/r"]} =
             OSSigning.command("scripts/signing/sign-macos.sh", "/r")

    if System.find_executable("pwsh") || System.find_executable("powershell") do
      {shell, args} = OSSigning.command("scripts/signing/sign-windows.ps1", "/r")
      assert Path.basename(shell, ".exe") in ["pwsh", "powershell"]
      assert Enum.take(args, -3) == ["-File", "scripts/signing/sign-windows.ps1", "/r"]
    end
  end
end
