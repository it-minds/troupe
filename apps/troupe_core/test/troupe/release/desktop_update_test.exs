defmodule Troupe.Release.DesktopUpdateTest do
  @moduledoc """
  The desktop app's update is signed with the release key (#66, Decision 874):
  `release.yml`'s publish job runs `scripts/release-desktop-update.exs` before the manifest,
  which writes a `.sig` beside each file the desktop app updates itself from, as Tauri's
  updater reads one, and `latest.json`, its document; the manifest then names them with
  everything else. The script is run here as CI runs it, with throwaway keys made in the
  test.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.{Manifest, Minisign}

  @root Path.expand("../../../../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/release.yml")
  @native Path.join(@root, ".github/workflows/native.yml")
  @script Path.join(@root, "scripts/release-desktop-update.exs")
  @manifest Path.join(@root, "scripts/release-manifest.exs")
  @base "https://example.test/releases/download/v9.9.9-beta"

  test "the publish job signs the desktop app's update with the release key, before the manifest" do
    {:ok, workflow} = YamlElixir.read_from_file(@workflow)
    steps = workflow["jobs"]["publish"]["steps"]

    step =
      Enum.find(steps, &String.contains?(&1["run"] || "", "scripts/release-desktop-update.exs"))

    assert step, "no step of the publish job runs scripts/release-desktop-update.exs"

    assert step["env"]["RELEASE_MINISIGN_KEY"] == "${{ secrets.RELEASE_MINISIGN_KEY }}"
    run = step["run"]

    {desktop, _} = :binary.match(run, "release-desktop-update.exs")
    {manifest, _} = :binary.match(run, "release-manifest.exs")
    assert desktop < manifest, "the manifest is written before the desktop app's update is signed"
    assert run =~ "dist/latest.json dist/*.sig", "latest.json and the signatures are not uploaded"

    # The macOS archive the updater reads is built and kept with the installers.
    {:ok, native} = YamlElixir.read_from_file(@native)
    desktop_steps = native["jobs"]["desktop"]["steps"]
    assert Enum.any?(desktop_steps, &((&1["run"] || "") =~ "_universal.app.tar.gz"))

    kept = Enum.find(desktop_steps, &(&1["name"] == "Keep the installers"))
    assert kept["with"]["path"] =~ "*.app.tar.gz"
  end

  defp dist(tmp) do
    dist = Path.join(tmp, "dist")
    File.mkdir_p!(dist)
    File.write!(Path.join(dist, "Troupe_9.9.9_x64-setup.exe"), "a windows setup\n")
    File.write!(Path.join(dist, "Troupe_9.9.9_universal.app.tar.gz"), "a macos archive\n")
    File.write!(Path.join(dist, "Troupe_9.9.9_amd64.AppImage"), "a linux appimage\n")
    File.write!(Path.join(dist, "Troupe_9.9.9_universal.dmg"), "not an update\n")
    File.write!(Path.join(dist, "troupe-daemon-9.9.9-beta-windows_x86_64.tar.gz"), "a daemon\n")
    dist
  end

  defp keys(tmp, publics) do
    path = Path.join(tmp, "release-keys.txt")

    File.write!(
      path,
      "# the test's\n" <> Enum.map_join(publics, "\n", &Minisign.encode_public_key/1)
    )

    path
  end

  defp run(script, args, env) do
    elixir = System.find_executable("elixir") || flunk("no elixir on the PATH")
    System.cmd(elixir, [script | args], env: env, stderr_to_stdout: true)
  end

  @tag :tmp_dir
  test "each update file gets the signature Tauri reads, latest.json names them, and the manifest both",
       %{tmp_dir: tmp} do
    dist = dist(tmp)
    {public, secret} = Minisign.generate_keypair()
    keys = keys(tmp, [public])

    env = [
      {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(secret)},
      {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
    ]

    {out, status} = run(@script, ["9.9.9-beta", dist, "--base", @base, "--keys", keys], env)
    assert status == 0, out

    for file <-
          ~w(Troupe_9.9.9_x64-setup.exe Troupe_9.9.9_universal.app.tar.gz Troupe_9.9.9_amd64.AppImage) do
      # Tauri's `.sig`: the minisign signature, base64-encoded, by the release key, its
      # trusted comment naming the file and the version the updater holds the offer to.
      {:ok, text} = File.read!(Path.join(dist, file <> ".sig")) |> Base.decode64()

      assert {:ok, %{trusted_comment: comment}} =
               Minisign.verify(File.read!(Path.join(dist, file)), text, [public])

      assert comment =~ "\tfile:#{file}\t"
      assert comment =~ "\tversion:9.9.9-beta"
    end

    refute File.exists?(Path.join(dist, "Troupe_9.9.9_universal.dmg.sig"))

    latest = dist |> Path.join("latest.json") |> File.read!() |> JSON.decode!()
    assert latest["version"] == "9.9.9-beta"

    assert latest["platforms"]["windows-x86_64"] == %{
             "url" => "#{@base}/Troupe_9.9.9_x64-setup.exe",
             "signature" => File.read!(Path.join(dist, "Troupe_9.9.9_x64-setup.exe.sig"))
           }

    assert Map.keys(latest["platforms"]) |> Enum.sort() ==
             ~w(darwin-aarch64 darwin-aarch64-app darwin-x86_64 darwin-x86_64-app
                linux-x86_64 linux-x86_64-appimage windows-x86_64 windows-x86_64-nsis)

    # The manifest, written after, names the signatures and the document as the desktop
    # app's: one signature chain over all of it.
    {out, status} = run(@manifest, ["9.9.9-beta", dist, "--keys", keys], env)
    assert status == 0, out
    {:ok, manifest} = dist |> Path.join("manifest.json") |> File.read!() |> Manifest.decode()

    assert %{component: "desktop", target: nil} =
             Enum.find(manifest.artifacts, &(&1.file == "latest.json"))

    assert %{component: "desktop", target: "windows_x86_64"} =
             Enum.find(manifest.artifacts, &(&1.file == "Troupe_9.9.9_x64-setup.exe.sig"))
  end

  @tag :tmp_dir
  test "refused without the key, or with a key that is not the first, and nothing is written",
       %{tmp_dir: tmp} do
    dist = dist(tmp)
    {public, secret} = Minisign.generate_keypair()
    {other_public, other_secret} = Minisign.generate_keypair()
    keys = keys(tmp, [public, other_public])
    args = ["9.9.9-beta", dist, "--base", @base, "--keys", keys]

    {out, status} =
      run(@script, args, [{"RELEASE_MINISIGN_KEY", ""}, {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}])

    assert status != 0
    assert out =~ "RELEASE_MINISIGN_KEY is not set"

    {out, status} =
      run(@script, args, [
        {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(other_secret)},
        {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
      ])

    assert status != 0
    assert out =~ "not the first"

    {out, status} =
      run(@script, ["9.9.9-beta", Path.join(tmp, "empty"), "--base", @base, "--keys", keys], [
        {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(secret)},
        {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
      ])

    assert status != 0
    assert out =~ "not a directory"

    refute File.exists?(Path.join(dist, "latest.json"))
    assert Path.wildcard(Path.join(dist, "*.sig")) == []
  end

  @tag :tmp_dir
  test "a key rotation signs the update with the key being retired, which the apps updating to it trust",
       %{tmp_dir: tmp} do
    dist = dist(tmp)
    {new_public, new_secret} = Minisign.generate_keypair()
    {old_public, old_secret} = Minisign.generate_keypair()
    keys = keys(tmp, [new_public, old_public])

    {out, status} =
      run(@script, ["9.9.9-beta", dist, "--base", @base, "--keys", keys], [
        {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(new_secret)},
        {"RELEASE_MINISIGN_KEY_PREVIOUS", Minisign.encode_secret_key(old_secret)}
      ])

    assert status == 0, out

    {:ok, text} =
      dist |> Path.join("Troupe_9.9.9_x64-setup.exe.sig") |> File.read!() |> Base.decode64()

    setup = File.read!(Path.join(dist, "Troupe_9.9.9_x64-setup.exe"))

    # An app built before the rotation trusts the old key alone, and one built from it both.
    assert {:ok, _} = Minisign.verify(setup, text, [old_public])
    assert {:ok, _} = Minisign.verify(setup, text, [new_public, old_public])
    assert {:error, _} = Minisign.verify(setup, text, [new_public])
  end
end
