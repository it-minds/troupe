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

  describe "signed in to a plane (Decision 868)" do
    test "the version installed is the plane's recommended one, checked as any other", ctx do
      url = release!(ctx, "1.1.0")
      plane = plane(%{"recommended" => "1.1.0"})

      assert Update.run(:check, opts(ctx, url, plane: plane)) == 0
      out = lines()
      assert "  plane          https://plane.example.test recommends 1.1.0" in out
      assert "troupe update would install 1.1.0 over troupe-daemon 1.0.0 and troupe 1.0.0." in out

      assert Update.run(:update, opts(ctx, url, plane: plane)) == 0
      assert "1.1.0, the version https://plane.example.test recommends" in lines()
      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
      assert Update.daemon_version(ctx.lib, false) == "1.1.0"
    end

    # B29's finding: somebody who controls a mirror can keep serving an older signed
    # release. Signed in, the plane names the version, and the mirror's older one is not it.
    test "a mirror cannot hold back the release the plane recommends", ctx do
      url = release!(ctx, "1.1.0")

      assert Update.run(:update, opts(ctx, url, plane: plane(%{"recommended" => "1.2.0"}))) == 1
      assert Enum.any?(lines(), &(&1 =~ "is 1.1.0, not 1.2.0; nothing is installed"))
      assert_unchanged(ctx)
      refute_received :daemon_asked
    end

    test "a version the plane blocks is never installed, the latest or one named", ctx do
      url = release!(ctx, "1.1.0")
      plane = plane(%{"blocked" => ["1.1.0"]})

      assert Update.run(:update, opts(ctx, url, plane: plane)) == 1

      assert Enum.any?(
               lines(),
               &(&1 =~
                   "the plane at https://plane.example.test blocks troupe 1.1.0; nothing is installed")
             )

      assert Update.run(:update, opts(ctx, url, plane: plane, version: "1.1.0")) == 1
      assert Enum.any?(lines(), &(&1 =~ "blocks troupe 1.1.0"))
      assert_unchanged(ctx)
      refute_received :daemon_asked
    end

    test "nor one older than the plane's minimum for a component it replaces", ctx do
      url = release!(ctx, "1.0.5")
      plane = plane(%{"minimum" => "1.0.0"}, %{"minimum" => "1.1.0"})

      assert Update.run(:update, opts(ctx, url, plane: plane, version: "1.0.5")) == 1

      assert Enum.any?(
               lines(),
               &(&1 =~
                   "1.0.5 is older than the oldest troupe-daemon the plane at https://plane.example.test serves (1.1.0)")
             )

      assert_unchanged(ctx)
    end

    # Moving back is the person's to ask for: a plane, or whoever holds one, cannot walk a
    # machine back to an old release of its choosing by blocking the one it has.
    test "a blocked version with an older one recommended is moved back only when named", ctx do
      url = release!(ctx, "0.9.0")
      blocked = %{"recommended" => "0.9.0", "blocked" => ["1.0.0"]}
      plane = plane(blocked, blocked)

      assert Update.run(:update, opts(ctx, url, plane: plane)) == 1

      assert Enum.any?(
               lines(),
               &(&1 =~
                   "blocks troupe-daemon 1.0.0, and the version it recommends, 0.9.0, is older: " <>
                     "troupe update --version 0.9.0 moves back to it")
             )

      assert_unchanged(ctx)

      assert Update.run(:update, opts(ctx, url, plane: plane, version: "0.9.0")) == 0
      assert File.read!(ctx.tui) == "troupe 0.9.0\n"
      assert Update.daemon_version(ctx.lib, false) == "0.9.0"
    end

    test "a newer version than the plane recommends, and not blocked, is left alone", ctx do
      url = release!(ctx, "0.9.0")

      assert Update.run(:update, opts(ctx, url, plane: plane(%{"recommended" => "0.9.0"}))) == 0
      assert Enum.any?(lines(), &(&1 =~ "Nothing to update"))
      assert_unchanged(ctx)
    end

    test "a plane that recommends nothing leaves the latest release, unless it blocks it", ctx do
      url = release!(ctx, "1.1.0")

      assert Update.run(:update, opts(ctx, url, plane: plane(%{"blocked" => ["1.0.9"]}))) == 0
      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
    end

    # #657: a closed network's machines update from where the plane says releases are, each
    # under `v<version>/`, and still only from what the release key signed.
    test "the release comes from where the plane says releases are", ctx do
      "file://" <> dir = release!(ctx, "1.1.0")
      mirror = Path.join(ctx.root, "mirror-#{System.unique_integer([:positive])}")
      File.mkdir_p!(mirror)
      File.rename!(dir, Path.join(mirror, "v1.1.0"))
      plane = Map.put(plane(%{"recommended" => "1.1.0"}), :release_url, "file://" <> mirror)

      assert Update.run(:update, opts(ctx, nil, plane: plane)) == 0
      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
      assert Update.daemon_version(ctx.lib, false) == "1.1.0"
    end

    test "a plane's mirror with no version named or recommended asks for one", ctx do
      plane = Map.put(plane(%{}), :release_url, "file://" <> ctx.root)

      assert Update.run(:update, opts(ctx, nil, plane: plane)) == 1

      assert Enum.any?(
               lines(),
               &(&1 =~ "recommends no version: name one with troupe update --version X")
             )

      assert_unchanged(ctx)
    end

    test "a mirror holding another release than the one named under its version is refused",
         ctx do
      "file://" <> dir = release!(ctx, "1.0.5")
      mirror = Path.join(ctx.root, "mirror-#{System.unique_integer([:positive])}")
      File.mkdir_p!(mirror)
      File.rename!(dir, Path.join(mirror, "v1.1.0"))
      plane = Map.put(plane(%{"recommended" => "1.1.0"}), :release_url, "file://" <> mirror)

      assert Update.run(:update, opts(ctx, nil, plane: plane)) == 1
      assert Enum.any?(lines(), &(&1 =~ "is 1.0.5, not 1.1.0; nothing is installed"))
      assert_unchanged(ctx)
    end
  end

  describe "--latest" do
    test "picks the newest release whose manifest supports the plane's version", ctx do
      listed = [
        {"1.3.0", release!(ctx, "1.3.0", supports: ">= 2.0.0")},
        {"1.2.0", release!(ctx, "1.2.0", supports: ">= 1.0.0 and < 2.0.0")},
        {"1.1.0", release!(ctx, "1.1.0", supports: ">= 1.0.0")}
      ]

      plane = plane(%{"recommended" => "1.1.0"})

      assert Update.run(:update, latest(ctx, listed, plane: plane)) == 0
      out = lines()

      assert ("  passed over 1.3.0: it supports planes >= 2.0.0, and the plane at " <>
                "https://plane.example.test is 1.5.0") in out

      assert ("1.2.0, the newest release that supports https://plane.example.test " <>
                "(it recommends 1.1.0)") in out

      assert File.read!(ctx.tui) == "troupe 1.2.0\n"
      assert Update.daemon_version(ctx.lib, false) == "1.2.0"
    end

    test "passes over a release the plane blocks", ctx do
      listed = [
        {"1.2.0", release!(ctx, "1.2.0", supports: ">= 1.0.0")},
        {"1.1.5", release!(ctx, "1.1.5", supports: ">= 1.0.0")}
      ]

      plane = plane(%{"recommended" => "1.1.0", "blocked" => ["1.2.0"]})

      assert Update.run(:update, latest(ctx, listed, plane: plane)) == 0
      out = lines()

      assert "  passed over 1.2.0: the plane at https://plane.example.test blocks troupe 1.2.0" in out

      assert File.read!(ctx.tui) == "troupe 1.1.5\n"
    end

    test "stops at a release below the plane's minimum", ctx do
      test = self()

      fetch = fn url, dest ->
        send(test, {:fetched, url})
        Update.fetch(url, dest)
      end

      oldest = release!(ctx, "1.0.7", supports: ">= 1.0.0")

      listed = [
        {"1.2.0", release!(ctx, "1.2.0", supports: ">= 2.0.0")},
        {"1.0.8", release!(ctx, "1.0.8", supports: ">= 1.0.0")},
        {"1.0.7", oldest}
      ]

      plane = plane(%{"minimum" => "1.1.0"})

      assert Update.run(:update, latest(ctx, listed, plane: plane, fetch: fetch)) == 1

      assert Enum.any?(
               lines(),
               &(&1 =~
                   "troupe update --latest found nothing to install for the plane at " <>
                     "https://plane.example.test, which recommends no version: 1.0.8 is older " <>
                     "than the oldest troupe the plane at https://plane.example.test serves (1.1.0)")
             )

      refute_received {:fetched, ^oldest <> _}
      assert_unchanged(ctx)
    end

    test "reads a manifest without supports as unknown, bar the recommended one", ctx do
      listed = [
        {"1.2.0", release!(ctx, "1.2.0")},
        {"1.1.0", release!(ctx, "1.1.0")}
      ]

      plane = plane(%{"recommended" => "1.1.0"})

      # The recommended one is fetched by its version, from where releases are.
      {"1.1.0", url} = List.last(listed)
      assert Update.run(:update, latest(ctx, listed, plane: plane, release_url: url)) == 0
      out = lines()

      assert ("  passed over 1.2.0: its manifest says nothing of which planes it supports, " <>
                "from before releases said so") in out

      assert ("1.1.0, the version https://plane.example.test recommends: no newer release says " <>
                "it supports this plane; it says nothing of which planes it supports, and the " <>
                "plane's word covers it") in out

      assert File.read!(ctx.tui) == "troupe 1.1.0\n"
    end

    test "not signed in, picks the newest release", ctx do
      listed = [
        {"1.2.0", release!(ctx, "1.2.0")},
        {"1.1.0", release!(ctx, "1.1.0", supports: ">= 9.0.0")}
      ]

      assert Update.run(:update, latest(ctx, listed)) == 0
      assert "1.2.0, the newest release" in lines()
      assert File.read!(ctx.tui) == "troupe 1.2.0\n"
    end

    test "looks at the 20 newest releases and no more", ctx do
      listed = for n <- 30..1//-1, do: {"1.9.#{n}", "file://" <> Path.join(ctx.root, "gone-#{n}")}

      assert Update.run(:update, latest(ctx, listed)) == 1
      out = lines()
      assert Enum.count(out, &String.starts_with?(&1, "  passed over ")) == 20

      assert Enum.any?(
               out,
               &(&1 =~
                   "none of the 20 newest releases says it supports this plane, and troupe " <>
                     "update looked no further")
             )

      assert_unchanged(ctx)
    end

    test "--recommended, the default, lists no releases", ctx do
      url = release!(ctx, "1.1.0", supports: ">= 1.0.0")
      releases = fn _s -> flunk("--recommended listed the releases") end
      plane = plane(%{"recommended" => "1.1.0"})

      assert Update.run(:update, opts(ctx, url, plane: plane, releases: releases)) == 0
      assert "1.1.0, the version https://plane.example.test recommends" in lines()
    end

    test "troupe doctor's line names a newer supported release", ctx do
      listed = [
        {"1.2.0", release!(ctx, "1.2.0", supports: ">= 1.0.0")},
        {"1.1.0", release!(ctx, "1.1.0", supports: ">= 1.0.0")}
      ]

      plane = plane(%{"recommended" => "1.1.0"})

      assert %{
               name: "update",
               state: :ok,
               detail: "1.2.0 supports this plane; `troupe update --latest` installs it"
             } = Update.doctor_check(latest(ctx, listed, plane: plane))

      assert Update.doctor_check(latest(ctx, tl(listed), plane: plane)) == nil
      assert Update.doctor_check(latest(ctx, listed, plane: plane, installed: "1.2.0")) == nil
      assert Update.doctor_check(latest(ctx, listed)) == nil
      assert_unchanged(ctx)
    end
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

  # -- every component the installers put here -----------------------------------

  # The AppImage beside the programs, and its menu entry, as install.sh leaves them.
  defp appimage!(ctx, version) do
    path = Path.join(ctx.root, "bin/troupe-desktop")
    entry = Path.join(ctx.root, "applications/troupe.desktop")
    File.mkdir_p!(Path.dirname(entry))
    File.write!(path, "desktop #{version}\n")
    File.chmod!(path, 0o755)

    File.write!(
      entry,
      "[Desktop Entry]\nType=Application\nName=Troupe\nComment=The Troupe desktop app, release #{version}\nExec=#{path}\n"
    )

    %{kind: :appimage, path: path, entry: entry}
  end

  # VS Code's command line as a stub: it lists the extension at `version`, and records an
  # install, answering as `code` does.
  defp code_stub(test, version) do
    fn
      ["/fake/code", "--list-extensions", "--show-versions"] ->
        {:ok, "objective-mj.troupe@#{version}\nms-python.python@2024.1.0\n", 0}

      ["/fake/code", "--install-extension", vsix, "--force"] ->
        send(test, {:installed_extension, vsix, File.read!(vsix)})
        {:ok, "Extension 'troupe.vsix' was successfully installed.\n", 0}
    end
  end

  test "extras: checked, replaced after the core, and the AppImage rolled back", ctx do
    test = self()
    desktop = appimage!(ctx, "1.0.0")
    url = release!(ctx, "1.1.0-beta", desktop: :appimage, vsix: true)
    opts = opts(ctx, url, desktop: desktop, vscode: "/fake/code", run: code_stub(test, "1.0.0"))

    assert Update.run(:check, opts) == 0
    out = lines()

    assert Enum.any?(
             out,
             &(&1 =~ ~r/the desktop app\s+1\.0\.0\s+#{Regex.escape(desktop.path)}/)
           )

    assert Enum.any?(out, &(&1 =~ ~r/the VS Code extension\s+1\.0\.0\s+\/fake\/code/))

    assert "troupe update would install 1.1.0-beta over troupe-daemon 1.0.0 and troupe 1.0.0 and the desktop app 1.0.0 and the VS Code extension 1.0.0." in out

    assert Update.run(:update, opts) == 0
    out = lines()
    assert File.read!(ctx.tui) == "troupe 1.1.0-beta\n"
    assert Update.daemon_version(ctx.lib, false) == "1.1.0-beta"
    # The desktop app's version drops the pre-release part, as its files are named.
    assert "  the desktop app  1.0.0 -> 1.1.0" in out
    assert File.read!(desktop.path) == "desktop 1.1.0\n"
    assert File.read!(desktop.path <> ".previous") == "desktop 1.0.0\n"
    assert File.read!(desktop.path <> ".version") == "1.1.0\n"
    assert File.read!(desktop.entry) =~ "release 1.1.0\n"
    assert Update.desktop_version(desktop, %{}) == "1.1.0"
    assert_received {:installed_extension, vsix, "vsix 1.1.0-beta\n"}
    refute File.exists?(vsix)
    refute File.exists?(desktop.path <> ".new")
    assert Enum.any?(out, &(&1 =~ "keeps the old build until it is restarted"))

    assert Enum.any?(
             out,
             &(&1 =~ "the VS Code extension 1.1.0-beta is installed with /fake/code")
           )

    assert List.last(out) =~ "troupe update --rollback"

    # Rolled back, the AppImage and its version trade places; the extension keeps none.
    assert Update.run(:rollback, opts) == 0
    assert File.read!(desktop.path) == "desktop 1.0.0\n"
    assert File.read!(desktop.path <> ".previous") == "desktop 1.1.0\n"
    assert File.read!(desktop.path <> ".version") == "1.0.0\n"
    assert File.read!(desktop.entry) =~ "release 1.0.0\n"
    assert File.read!(ctx.tui) == "troupe 1.0.0\n"
    refute_received {:installed_extension, _, _}

    assert Update.run(:rollback, opts) == 0
    assert File.read!(desktop.path) == "desktop 1.1.0\n"
    assert Update.desktop_version(desktop, %{}) == "1.1.0"
  end

  test "extras: a release with no desktop app here leaves it, says so, installs the rest", ctx do
    desktop = appimage!(ctx, "1.0.0")
    url = release!(ctx, "1.1.0", vsix: false)
    opts = opts(ctx, url, desktop: desktop)

    assert Update.run(:update, opts) == 0
    out = lines()

    assert "  the desktop app 1.0.0 is left as it is: release 1.1.0 has none for this computer" in out

    assert File.read!(ctx.tui) == "troupe 1.1.0\n"
    assert File.read!(desktop.path) == "desktop 1.0.0\n"
    refute File.exists?(desktop.path <> ".previous")
  end

  test "extras: an extension that will not install is said, the core stays installed", ctx do
    url = release!(ctx, "1.1.0", vsix: true)

    run = fn
      ["/fake/code", "--list-extensions", "--show-versions"] ->
        {:ok, "objective-mj.troupe@1.0.0\n", 0}

      ["/fake/code", "--install-extension", _vsix, "--force"] ->
        {:ok, "Failed Installing Extensions: EACCES\n", 1}
    end

    opts = opts(ctx, url, vscode: "/fake/code", run: run)
    assert Update.run(:update, opts) == 1
    out = lines()
    assert File.read!(ctx.tui) == "troupe 1.1.0\n"
    assert Update.daemon_version(ctx.lib, false) == "1.1.0"

    assert Enum.any?(
             out,
             &(&1 =~
                 "the VS Code extension 1.0.0 is left as it is: /fake/code --install-extension exited with 1 (Failed Installing Extensions: EACCES)")
           )

    assert List.last(out) =~ "the VS Code extension was not replaced; the rest is installed"
  end

  test "extras: an extension at the release's version is left alone, none listed is not installed",
       ctx do
    url = release!(ctx, "1.1.0", vsix: true)

    run = fn ["/fake/code", "--list-extensions", "--show-versions"] ->
      {:ok, "objective-mj.troupe@1.1.0\n", 0}
    end

    assert Update.run(:update, opts(ctx, url, vscode: "/fake/code", run: run)) == 0
    refute Enum.any?(lines(), &(&1 =~ "VS Code extension"))

    run = fn ["/fake/code", "--list-extensions", "--show-versions"] ->
      {:ok, "ms-python.python@2024.1.0\n", 0}
    end

    assert Update.run(:check, opts(ctx, url, vscode: "/fake/code", run: run)) == 0
    assert Enum.any?(lines(), &(&1 =~ ~r/the VS Code extension\s+not installed/))
  end

  test "extras: the macOS app bundle is copied out of the disk image, the old one kept", ctx do
    test = self()
    app = Path.join(ctx.root, "Applications/Troupe.app")

    plist = fn version ->
      "<plist><dict><key>CFBundleShortVersionString</key>\n<string>#{version}</string></dict></plist>"
    end

    File.mkdir_p!(Path.join(app, "Contents"))
    File.write!(Path.join(app, "Contents/Info.plist"), plist.("1.0.0"))
    desktop = %{kind: :mac_app, path: app}
    url = release!(ctx, "1.1.0", desktop: :dmg)

    run = fn
      ["hdiutil", "attach", "-nobrowse", "-readonly", "-quiet", "-mountpoint", mount, dmg] ->
        assert File.read!(dmg) == "desktop 1.1.0\n"
        File.mkdir_p!(Path.join(mount, "Troupe.app/Contents"))
        File.write!(Path.join(mount, "Troupe.app/Contents/Info.plist"), plist.("1.1.0"))
        {:ok, "", 0}

      ["hdiutil", "detach", "-quiet", mount] ->
        send(test, {:detached, mount})
        File.rm_rf!(Path.join(mount, "Troupe.app"))
        {:ok, "", 0}
    end

    opts = opts(ctx, url, desktop: desktop, run: run)
    assert Update.run(:check, opts) == 0
    assert Enum.any?(lines(), &(&1 =~ ~r/the desktop app\s+1\.0\.0\s+#{Regex.escape(app)}/))

    assert Update.run(:update, opts) == 0
    assert Update.desktop_version(desktop, %{}) == "1.1.0"
    assert Update.desktop_version(%{kind: :mac_app, path: app <> ".previous"}, %{}) == "1.0.0"
    assert_received {:detached, _mount}
    refute File.exists?(app <> ".new")
    refute File.exists?(app <> ".new.dmg")
    refute File.exists?(app <> ".new.mount")

    assert Update.run(:rollback, opts) == 0
    assert Update.desktop_version(desktop, %{}) == "1.0.0"
    assert Update.desktop_version(%{kind: :mac_app, path: app <> ".previous"}, %{}) == "1.1.0"
  end

  test "extras: on Windows the release's setup runs silently and keeps no previous", ctx do
    test = self()
    url = release!(ctx, "1.1.0", desktop: :setup)

    run = fn
      ["reg", "query", key, "/v", "DisplayVersion"] ->
        assert key =~ "Uninstall\\Troupe"

        {:ok, "\r\nHKEY_CURRENT_USER\\...\\Troupe\r\n    DisplayVersion    REG_SZ    1.0.0\r\n",
         0}

      [setup, "/S"] ->
        send(test, {:setup, setup, File.read!(setup)})
        {:ok, "", 0}
    end

    opts = opts(ctx, url, desktop: %{kind: :windows_setup, path: nil}, windows?: true, run: run)
    assert Update.run(:update, opts) == 0
    out = lines()
    assert_received {:setup, setup, "desktop 1.1.0\n"}
    assert Path.basename(setup) == "Troupe_1.1.0_x64-setup.exe"
    refute File.exists?(setup)

    assert Enum.any?(
             out,
             &(&1 =~
                 "the desktop app 1.1.0 is set up (1.0.0 before; its setup keeps no previous)")
           )

    # A setup that would not run leaves troupe and troupe-daemon installed and says so.
    url = release!(ctx, "1.2.0", desktop: :setup)

    run = fn
      ["reg", "query", _key, "/v", "DisplayVersion"] ->
        {:ok, "    DisplayVersion    REG_SZ    1.1.0\r\n", 0}

      [_setup, "/S"] ->
        {:ok, "", 2}
    end

    assert Update.run(
             :update,
             opts(ctx, url,
               desktop: %{kind: :windows_setup, path: nil},
               windows?: true,
               run: run
             )
           ) == 1

    assert Enum.any?(
             lines(),
             &(&1 =~ "exited with 2; close Troupe if it is running and run troupe update again")
           )
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

  # What a plane's `me.client_versions` said, as the CLI hands it over.
  defp plane(tui, daemon \\ %{}) do
    %{
      url: "https://plane.example.test",
      version: "1.5.0",
      versions: %{"tui" => tui, "daemon" => daemon}
    }
  end

  # `--latest` over releases each in its own directory, newest first.
  defp latest(ctx, listed, extra \\ []) do
    opts(ctx, nil, [pick: :latest, releases: fn _s -> {:ok, listed} end] ++ extra)
  end

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
        # Never this machine's desktop app or VS Code: a test names its own or none.
        desktop: nil,
        vscode: nil,
        run: fn argv -> flunk("no program was expected to run, and #{inspect(argv)} was") end,
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

  # A release of a troupe and a troupe-daemon for linux_x86_64, signed; with `desktop:`
  # the desktop app's files the installers use (`:appimage`, `:dmg`, `:setup`, or a list),
  # with `vsix: true` the VS Code extension, and with `supports:` the plane requirement its
  # manifest signs.
  defp release!(ctx, version, extra \\ []) do
    dir = Path.join(ctx.root, "release-#{version}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "troupe-#{version}-linux_x86_64"), "troupe #{version}\n")
    desktop = version |> String.split("-") |> hd()

    for kind <- List.wrap(Keyword.get(extra, :desktop, [])) do
      name =
        case kind do
          :appimage -> "Troupe_#{desktop}_amd64.AppImage"
          :dmg -> "Troupe_#{desktop}_universal.dmg"
          :setup -> "Troupe_#{desktop}_x64-setup.exe"
        end

      File.write!(Path.join(dir, name), "desktop #{desktop}\n")
    end

    if Keyword.get(extra, :vsix, false),
      do: File.write!(Path.join(dir, "troupe.vsix"), "vsix #{version}\n")

    tree = Path.join(ctx.root, "tree-#{System.unique_integer([:positive])}")
    daemon_tree!(tree, version)

    files =
      for f <- ~w(bin/troupe-daemon bin/troupe-daemon.cmd releases/start_erl.data),
          do: {String.to_charlist(f), String.to_charlist(Path.join(tree, f))}

    archive = Path.join(dir, "troupe-daemon-#{version}-linux_x86_64.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(archive), files, [:compressed])

    supports =
      if plane = extra[:supports], do: %{plane: plane, protocol: "1"}

    manifest = Manifest.encode(Manifest.build(version, dir, supports))
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
