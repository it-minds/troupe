defmodule Troupe.UpdateTest do
  @moduledoc """
  `troupe update` (#66, Decision 865) against a release in a directory, as
  `TROUPE_RELEASE_URL=file://...` names one: signed with a throwaway key made here, and
  installed over a troupe and a troupe-daemon in a scratch directory, never this machine's.
  The daemon is a stand-in that says when it was asked to stop; the real one's answer is
  `daemon_stop_test.exs`'s, in the gateway.
  """

  use ExUnit.Case, async: true

  alias Troupe.Release.{Manifest, Minisign}
  alias Troupe.Update

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    {public, secret} = Minisign.generate_keypair()
    tui = Path.join(root, "bin/troupe")
    lib = Path.join(root, "lib/troupe-daemon")
    File.mkdir_p!(Path.dirname(tui))
    File.write!(tui, "troupe 1.0.0\n")
    daemon_tree!(lib, "1.0.0")
    %{root: root, public: public, secret: secret, tui: tui, lib: lib}
  end

  test "--check says what is installed, the release, and what an update would do", ctx do
    url = release!(ctx, "1.1.0")
    assert Update.run(:check, opts(ctx, url)) == 0
    out = lines()

    assert Enum.any?(out, &(&1 =~ ~r/troupe\s+1\.0\.0\s+#{Regex.escape(ctx.tui)}/))
    assert Enum.any?(out, &(&1 =~ ~r/troupe-daemon\s+1\.0\.0\s+#{Regex.escape(ctx.lib)}/))
    assert Enum.any?(out, &(&1 =~ "release        1.1.0  #{url}"))
    assert Enum.any?(out, &(&1 =~ "signed by release key #{Minisign.key_id(ctx.public)}"))
    assert "troupe update would install 1.1.0 over troupe-daemon 1.0.0 and troupe 1.0.0." in out
    # A check changes nothing and asks the daemon nothing.
    refute_received :daemon_asked
    assert File.read!(ctx.tui) == "troupe 1.0.0\n"
  end

  for windows? <- [false, true] do
    test "an update swaps both in, keeping what was there; --rollback swaps back, and forward (windows?: #{windows?})",
         ctx do
      url = release!(ctx, "1.1.0")
      opts = opts(ctx, url, windows?: unquote(windows?))
      windows? = Keyword.fetch!(opts, :windows?)

      assert Update.run(:update, opts) == 0
      out = lines()
      assert_received :daemon_asked

      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
      assert File.read!(ctx.tui <> ".previous") == "troupe 1.0.0\n"
      assert Update.daemon_version(ctx.lib, windows?) == "1.1.0"
      assert Update.daemon_version(ctx.lib <> ".previous", windows?) == "1.0.0"
      refute File.exists?(ctx.tui <> ".new")
      refute File.exists?(ctx.lib <> ".new")
      refute File.exists?(ctx.lib <> ".new.tar.gz")
      assert "  troupe-daemon  1.0.0 -> 1.1.0" in out
      assert Enum.any?(out, &(&1 =~ "sha256 as signed"))
      assert List.last(out) =~ "troupe update --rollback"

      unless windows?, do: assert(File.stat!(ctx.tui).mode |> Bitwise.band(0o111) != 0)

      assert Update.run(:rollback, opts) == 0
      assert_received :daemon_asked
      assert File.read!(ctx.tui) == "troupe 1.0.0\n"
      assert File.read!(ctx.tui <> ".previous") == "troupe 1.1.0\n"
      assert Update.daemon_version(ctx.lib, windows?) == "1.0.0"
      assert Update.daemon_version(ctx.lib <> ".previous", windows?) == "1.1.0"
      refute File.exists?(ctx.tui <> ".swap")
      refute File.exists?(ctx.lib <> ".swap")

      assert Update.run(:rollback, opts) == 0
      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
      assert Update.daemon_version(ctx.lib, windows?) == "1.1.0"
    end
  end

  test "a second update keeps only the one before it as previous", ctx do
    assert Update.run(:update, opts(ctx, release!(ctx, "1.1.0"))) == 0
    assert Update.run(:update, opts(ctx, release!(ctx, "1.2.0"))) == 0
    assert File.read!(ctx.tui) == "troupe 1.2.0\n"
    assert File.read!(ctx.tui <> ".previous") == "troupe 1.1.0\n"
    assert Update.daemon_version(ctx.lib <> ".previous", false) == "1.1.0"
  end

  test "an artifact changed after the manifest was signed is refused, and nothing is replaced",
       ctx do
    url = release!(ctx, "1.1.0")
    artifact = Path.join(String.replace_prefix(url, "file://", ""), "troupe-1.1.0-linux_x86_64")
    # The same size, one byte different.
    File.write!(artifact, "troupe 1.1.1\n")

    assert Update.run(:update, opts(ctx, url)) == 1
    assert [why] = Enum.filter(lines(), &String.starts_with?(&1, "troupe update: "))
    assert why =~ "troupe-1.1.0-linux_x86_64 is not the file the signed manifest names"
    assert why =~ "nothing is installed"

    assert_unchanged(ctx)
    # Refused before the daemon was asked anything.
    refute_received :daemon_asked
  end

  test "a manifest changed after it was signed is refused before any artifact is fetched", ctx do
    url = release!(ctx, "1.1.0")
    manifest = Path.join(String.replace_prefix(url, "file://", ""), "manifest.json")
    File.write!(manifest, String.replace(File.read!(manifest), "1.1.0", "1.1.9"))
    test = self()

    fetch = fn u, dest ->
      send(test, {:fetched, Path.basename(u)})
      Update.fetch(u, dest)
    end

    assert Update.run(:update, opts(ctx, url, fetch: fetch)) == 1
    assert Enum.any?(lines(), &(&1 =~ "changed after it was signed; nothing is installed"))
    assert_received {:fetched, "manifest.json"}
    assert_received {:fetched, "manifest.json.minisig"}
    refute_received {:fetched, _artifact}
    assert_unchanged(ctx)
  end

  test "another key's release, an unsigned one, and a build with no key install nothing", ctx do
    {_other, other_secret} = Minisign.generate_keypair()
    url = release!(ctx, "1.1.0", secret: other_secret)
    assert Update.run(:update, opts(ctx, url)) == 1
    assert Enum.any?(lines(), &(&1 =~ "which this build does not trust"))

    url = release!(ctx, "1.2.0")
    File.rm!(Path.join(String.replace_prefix(url, "file://", ""), "manifest.json.minisig"))
    assert Update.run(:update, opts(ctx, url)) == 1
    assert Enum.any?(lines(), &(&1 =~ "has a manifest.json but no manifest.json.minisig"))

    url = release!(ctx, "1.3.0")
    File.rm!(Path.join(String.replace_prefix(url, "file://", ""), "manifest.json"))
    assert Update.run(:update, opts(ctx, url)) == 1
    assert Enum.any?(lines(), &(&1 =~ "has no manifest.json"))

    assert Update.run(:update, opts(ctx, release!(ctx, "1.4.0"), keys: [])) == 1
    assert Enum.any?(lines(), &(&1 =~ "this build trusts no release key"))
    # --check says the same, and is a failure too.
    assert Update.run(:check, opts(ctx, release!(ctx, "1.5.0"), keys: [])) == 1

    assert_unchanged(ctx)
    refute_received :daemon_asked
  end

  test "a release asked for by version must be that version", ctx do
    url = release!(ctx, "1.1.0")
    assert Update.run(:update, opts(ctx, url, version: "1.2.0")) == 1
    assert Enum.any?(lines(), &(&1 =~ "is 1.1.0, not 1.2.0; nothing is installed"))
    assert_unchanged(ctx)
  end

  test "the latest release replaces only what is older; one named replaces either way", ctx do
    url = release!(ctx, "0.9.0")
    assert Update.run(:update, opts(ctx, url)) == 0
    assert Enum.any?(lines(), &(&1 =~ "Nothing to update"))
    assert_unchanged(ctx)

    assert Update.run(:update, opts(ctx, url, version: "0.9.0")) == 0
    assert File.read!(ctx.tui) == "troupe 0.9.0\n"
    assert Update.daemon_version(ctx.lib, false) == "0.9.0"
  end

  test "a daemon that cannot be stopped between turns is nothing changed", ctx do
    url = release!(ctx, "1.1.0")
    refuse = fn _s -> {:error, "troupe-daemon did not stop; nothing changed"} end

    assert Update.run(:update, opts(ctx, url, daemon: refuse)) == 1
    assert Enum.any?(lines(), &(&1 =~ "did not stop; nothing changed"))
    assert_unchanged(ctx)
    refute File.exists?(ctx.tui <> ".new")
    refute File.exists?(ctx.lib <> ".new")
  end

  test "with no troupe-daemon installed, troupe alone is replaced and no daemon is asked", ctx do
    File.rm_rf!(ctx.lib)
    assert Update.run(:update, opts(ctx, release!(ctx, "1.1.0"))) == 0
    assert File.read!(ctx.tui) == "troupe 1.1.0\n"
    refute File.exists?(ctx.lib)
    refute_received :daemon_asked
  end

  test "a release with nothing for this machine says so", ctx do
    assert Update.run(:update, opts(ctx, release!(ctx, "1.1.0"), target: "macos_aarch64")) == 1
    assert Enum.any?(lines(), &(&1 =~ "release 1.1.0 has no troupe-daemon for macos_aarch64"))
    assert_unchanged(ctx)
  end

  test "--rollback with nothing to go back to says so", ctx do
    assert Update.run(:rollback, opts(ctx, nil)) == 1
    assert Enum.any?(lines(), &(&1 =~ "nothing to roll back to"))
    refute_received :daemon_asked
  end

  test "the latest release is the tag GitHub's redirect names" do
    assert Update.latest_tag("https://github.com/it-minds/troupe/releases/tag/v0.13.0-beta") ==
             "0.13.0-beta"

    assert Update.latest_tag("https://github.com/it-minds/troupe/releases") == nil
  end

  test "file:// URLs are read, and a missing file is :not_found", %{root: root} do
    path = Path.join(root, "a file")
    File.write!(path, "x")
    assert {:ok, "x"} = Update.fetch("file://" <> URI.encode(path), :binary)
    assert {:error, :not_found} = Update.fetch("file://" <> Path.join(root, "nothing"), :binary)
    assert {:error, _} = Update.fetch("ftp://example.test/x", :binary)
  end

  # -- helpers --------------------------------------------------------------------

  defp opts(ctx, url, extra \\ []) do
    test = self()

    Keyword.merge(
      [
        installed: "1.0.0",
        release_url: url,
        keys: [ctx.public],
        target: "linux_x86_64",
        tui: ctx.tui,
        lib: ctx.lib,
        windows?: false,
        out: &send(test, {:out, &1}),
        daemon: fn _s ->
          send(test, :daemon_asked)
          :ok
        end,
        sleep: fn _ms -> :ok end
      ],
      extra
    )
  end

  defp lines(acc \\ []) do
    receive do
      {:out, line} -> lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_unchanged(ctx) do
    assert File.read!(ctx.tui) == "troupe 1.0.0\n"
    assert Update.daemon_version(ctx.lib, false) == "1.0.0"
    refute File.exists?(ctx.tui <> ".previous")
    refute File.exists?(ctx.lib <> ".previous")
  end

  # A release of a troupe and a troupe-daemon for linux_x86_64, signed.
  defp release!(ctx, version, extra \\ []) do
    dir = Path.join(ctx.root, "release-#{version}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "troupe-#{version}-linux_x86_64"), "troupe #{version}\n")

    tree = Path.join(ctx.root, "tree-#{System.unique_integer([:positive])}")
    daemon_tree!(tree, version)

    files =
      for f <- ~w(bin/troupe-daemon bin/troupe-daemon.cmd releases/start_erl.data),
          do: {String.to_charlist(f), String.to_charlist(Path.join(tree, f))}

    archive = Path.join(dir, "troupe-daemon-#{version}-linux_x86_64.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(archive), files, [:compressed])

    manifest = Manifest.encode(Manifest.build(version, dir))
    File.write!(Path.join(dir, "manifest.json"), manifest)

    File.write!(
      Path.join(dir, "manifest.json.minisig"),
      Minisign.sign(manifest, Keyword.get(extra, :secret, ctx.secret))
    )

    "file://" <> dir
  end

  defp daemon_tree!(dir, version) do
    File.mkdir_p!(Path.join(dir, "bin"))
    File.mkdir_p!(Path.join(dir, "releases"))
    File.write!(Path.join(dir, "bin/troupe-daemon"), "#!/bin/sh\n")
    File.write!(Path.join(dir, "bin/troupe-daemon.cmd"), "@echo off\n")
    File.write!(Path.join(dir, "releases/start_erl.data"), "15.0 #{version}\n")
  end
end
