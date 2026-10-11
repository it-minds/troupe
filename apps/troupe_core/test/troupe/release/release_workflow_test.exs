defmodule Troupe.Release.ReleaseWorkflowTest do
  @moduledoc """
  The release signs what it publishes (#66, Decision 865): `release.yml`'s publish job
  writes `manifest.json` and its `.minisig` with the `release` environment's key before
  anything is published, and `scripts/release-manifest.exs`, which it runs, signs a
  release and refuses one it cannot sign. The script is run here as CI runs it, with a
  throwaway key made in the test.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.{Manifest, Minisign}

  @root Path.expand("../../../../..", __DIR__)
  @workflow Path.join(@root, ".github/workflows/release.yml")
  @script Path.join(@root, "scripts/release-manifest.exs")

  test "the publish job signs the manifest with the release environment's key, before it publishes" do
    {:ok, workflow} = YamlElixir.read_from_file(@workflow)
    publish = workflow["jobs"]["publish"]

    assert publish["environment"] == "release",
           "the publish job is not in the release environment"

    steps = publish["steps"]
    index = fn pred -> Enum.find_index(steps, pred) end
    sign = index.(&String.contains?(&1["run"] || "", "scripts/release-manifest.exs"))
    assert sign, "no step of the publish job runs scripts/release-manifest.exs"

    step = Enum.at(steps, sign)
    assert step["env"]["RELEASE_MINISIGN_KEY"] == "${{ secrets.RELEASE_MINISIGN_KEY }}"
    assert step["run"] =~ "manifest.json.minisig", "the signature is not uploaded"
    assert step["run"] =~ "manifest.json ", "the manifest is not uploaded"
    assert step["run"] =~ "SHA256SUMS"

    # Signed before the chart reaches the registry and before the release is published:
    # a release that cannot be signed stays a draft.
    assert sign < index.(&(&1["name"] == "The chart, to the registry"))
    assert sign < index.(&(&1["name"] == "Publish"))
  end

  @tag :tmp_dir
  test "the script signs every artifact of a release, and refuses without the key", %{
    tmp_dir: tmp
  } do
    elixir = System.find_executable("elixir") || flunk("no elixir on the PATH")
    dist = Path.join(tmp, "dist")
    File.mkdir_p!(dist)
    File.write!(Path.join(dist, "troupe-9.9.9-linux_x86_64"), "a tui\n")
    File.write!(Path.join(dist, "troupe-daemon-9.9.9-windows_x86_64.tar.gz"), "a daemon\n")
    File.write!(Path.join(dist, "install.sh"), "#!/bin/sh\n")
    # What an earlier attempt left is not an artifact.
    File.write!(Path.join(dist, "SHA256SUMS"), "stale\n")

    {public, secret} = Minisign.generate_keypair()
    keys = Path.join(tmp, "release-keys.txt")
    File.write!(keys, "# the test's\n#{Minisign.encode_public_key(public)}\n")

    run = fn env ->
      System.cmd(elixir, [@script, "9.9.9", dist, "--keys", keys],
        env: env,
        stderr_to_stdout: true
      )
    end

    {out, status} = run.([{"RELEASE_MINISIGN_KEY", ""}, {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}])
    assert status != 0
    assert out =~ "RELEASE_MINISIGN_KEY"
    refute File.exists?(Path.join(dist, "manifest.json.minisig"))

    {out, status} =
      run.([
        {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(secret)},
        {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
      ])

    assert status == 0, out
    manifest = File.read!(Path.join(dist, "manifest.json"))
    signature = File.read!(Path.join(dist, "manifest.json.minisig"))
    assert {:ok, _} = Minisign.verify(manifest, signature, [public])

    {:ok, decoded} = Manifest.decode(manifest)
    assert decoded.version == "9.9.9"

    assert Enum.map(decoded.artifacts, & &1.file) ==
             ~w(install.sh troupe-9.9.9-linux_x86_64 troupe-daemon-9.9.9-windows_x86_64.tar.gz)

    assert %{component: "tui", target: "linux_x86_64", size: 6} =
             Manifest.find(decoded, "tui", "linux_x86_64")

    # A key the release's list does not hold is refused, before anything is written.
    {_other_public, other_secret} = Minisign.generate_keypair()
    File.rm!(Path.join(dist, "manifest.json.minisig"))

    {out, status} =
      run.([
        {"RELEASE_MINISIGN_KEY", Minisign.encode_secret_key(other_secret)},
        {"RELEASE_MINISIGN_KEY_PREVIOUS", ""}
      ])

    assert status != 0
    assert out =~ "not in"
    refute File.exists?(Path.join(dist, "manifest.json.minisig"))
  end
end
