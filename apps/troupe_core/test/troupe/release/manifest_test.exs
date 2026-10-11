defmodule Troupe.Release.ManifestTest do
  @moduledoc """
  A release's `manifest.json` (Decision 865): what each file is, the bytes it is signed
  as, and a downloaded file checked against it.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.Manifest

  test "each file a release publishes is named for what it is" do
    v = "0.13.0-beta"

    assert Manifest.classify(v, "troupe-daemon-#{v}-linux_aarch64.tar.gz") ==
             {"daemon", "linux_aarch64"}

    assert Manifest.classify(v, "troupe-#{v}-windows_x86_64.exe") == {"tui", "windows_x86_64"}
    assert Manifest.classify(v, "troupe-#{v}-macos_aarch64") == {"tui", "macos_aarch64"}
    assert Manifest.classify(v, "troupe-#{v}.tgz") == {"chart", nil}
    assert Manifest.classify(v, "install.ps1") == {"installer", nil}
    assert Manifest.classify(v, "troupe.vsix") == {"vscode", nil}
    assert Manifest.classify(v, "NOTICE") == {"licence", nil}
    # The desktop app's carry the version without its pre-release part.
    assert Manifest.classify(v, "Troupe_0.13.0_x64-setup.exe") == {"desktop", "windows_x86_64"}
    assert Manifest.classify(v, "Troupe_0.13.0_x64_en-US.msi") == {"desktop", "windows_x86_64"}
    assert Manifest.classify(v, "Troupe_0.13.0_amd64.AppImage") == {"desktop", "linux_x86_64"}
    assert Manifest.classify(v, "Troupe-0.13.0-1.x86_64.rpm") == {"desktop", "linux_x86_64"}
    assert Manifest.classify(v, "Troupe_0.13.0_universal.dmg") == {"desktop", "macos_universal"}
    assert Manifest.classify(v, "troupe-#{v}-plan9_mips") == {"other", nil}
    assert Manifest.classify(v, "troupe-0.12.0-linux_x86_64") == {"other", nil}
  end

  @tag :tmp_dir
  test "it is written the same way every time, one artifact to a line, and reads back", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "troupe-1.0.0-linux_x86_64"), "tui")
    File.write!(Path.join(dir, "troupe-daemon-1.0.0-linux_x86_64.tar.gz"), "daemon")

    for own <- ~w(manifest.json manifest.json.minisig SHA256SUMS),
        do: File.write!(Path.join(dir, own), "x")

    File.mkdir_p!(Path.join(dir, "a-directory"))

    manifest = Manifest.build("1.0.0", dir)

    assert Enum.map(manifest.artifacts, & &1.file) ==
             ~w(troupe-1.0.0-linux_x86_64 troupe-daemon-1.0.0-linux_x86_64.tar.gz)

    bytes = Manifest.encode(manifest)
    assert bytes == Manifest.encode(Manifest.build("1.0.0", dir))
    assert {:ok, ^manifest} = Manifest.decode(bytes)

    lines = String.split(bytes, "\n")
    tui = Enum.find(lines, &(&1 =~ ~s("file": "troupe-1.0.0-linux_x86_64")))
    assert tui =~ ~s("sha256": "#{Manifest.sha256(Path.join(dir, "troupe-1.0.0-linux_x86_64"))}")
    assert tui =~ ~s("size": 3)
    assert Enum.at(lines, 2) == ~s(  "version": "1.0.0",)
  end

  test "a manifest a client cannot rely on is refused" do
    assert {:error, "is not a release manifest"} = Manifest.decode("not json")

    assert {:error, "is in format 2" <> _} =
             Manifest.decode(~s({"format": 2, "version": "1", "artifacts": []}))

    sha = String.duplicate("a", 64)

    path =
      ~s({"format": 1, "version": "1", "artifacts": [{"component": "tui", "target": null, "file": "../x", "size": 1, "sha256": "#{sha}"}]})

    assert {:error, "names a file" <> _} = Manifest.decode(path)

    short =
      ~s({"format": 1, "version": "1", "artifacts": [{"component": "tui", "file": "x", "size": 1, "sha256": "#{sha}"}]})

    assert {:error, "has an artifact without" <> _} = Manifest.decode(short)
  end

  @tag :tmp_dir
  test "a file is checked by its size, then its sha256", %{tmp_dir: dir} do
    path = Path.join(dir, "f")
    File.write!(path, "abc")
    entry = %{file: "f", size: 3, sha256: Manifest.sha256(path), component: "tui", target: nil}

    assert :ok = Manifest.check_file(entry, path)
    File.write!(path, "abd")

    assert {:error, "f is not the file the signed manifest names" <> _} =
             Manifest.check_file(entry, path)

    File.write!(path, "abcd")

    assert {:error, "f is 4 bytes, and the signed manifest says 3"} =
             Manifest.check_file(entry, path)
  end

  test "this machine's target, as a release names its builds" do
    assert Manifest.target({:win32, :nt}, "x86_64-pc-windows") == "windows_x86_64"
    assert Manifest.target({:unix, :darwin}, "aarch64-apple-darwin23.4.0") == "macos_aarch64"
    assert Manifest.target({:unix, :linux}, "x86_64-pc-linux-musl") == "linux_x86_64"
    assert Manifest.target({:unix, :linux}, "aarch64-unknown-linux-gnu") == "linux_aarch64"
    assert Manifest.target({:unix, :freebsd}, "x86_64-unknown-freebsd14") == nil
    assert Manifest.target({:unix, :linux}, "riscv64-unknown-linux-gnu") == nil
    assert Manifest.target() in [nil | Manifest.targets()]
  end
end
