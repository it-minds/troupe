defmodule Troupe.Update do
  @moduledoc """
  `troupe update`: a release, checked, then swapped in for the troupe and the
  troupe-daemon the installers put on this machine (#66), and for the desktop app and the
  VS Code extension where the installers put those too. Nothing is installed but what the
  release key signed.

      troupe update --check            what is installed, the release, and what an update would do
      troupe update [--recommended]    install the version the plane recommends, or the latest release
      troupe update --latest           install the newest release that supports the plane
      troupe update --version X        install X
      troupe update --rollback         put the previous troupe and troupe-daemon back

  **Which release.** `--recommended`, the default, is the plane's word: the version its
  administrators recommend, so a person who never thinks about versions lands on the one
  their IT supports. `--latest` is for the person who wants to go past it: the newest
  release whose signed manifest says it supports the plane's version (`supports.plane`,
  read from the plane's discovery document), and still none the plane blocks or holds
  below its minimum, since the plane refuses those at `initialize` and finding that out
  after the install is too late. A release from before manifests said what they support
  is not known to support anything and is passed over, but for the recommended one, which
  the plane's word covers. Releases are looked at newest first, from GitHub's list (or the
  one release `TROUPE_RELEASE_URL` names), at most 20 of them; not signed in to a plane,
  `--latest` is the newest release there is.

  **Where from.** `TROUPE_RELEASE_URL`, when it is set, is one release's assets, as the
  installers read it: a mirror, or a `file://` directory. Otherwise, signed in to a plane
  that names where its releases are (its signed `release.url`, #657), there: the version
  asked for under `v<version>/`. Otherwise GitHub's: the latest release is the one
  `/releases/latest` redirects to, and `--version X` is the tag `vX`.

  **What is checked, and when.** The release's `manifest.json` and its
  `manifest.json.minisig` come first, and nothing else is fetched until the signature
  holds against a key this build was compiled with (`Troupe.Release.Keys`) and the
  manifest names the version asked for. Each artifact is then downloaded beside what it
  replaces and checked against the manifest, its size and then its sha256. Only when all
  of them hold is anything replaced. Nothing that cannot be checked is ever installed: a
  build with no key, a release with no manifest or no signature, or one signed by a key
  this build does not trust, is refused in a sentence, with nothing changed.

  **Never under a running turn.** The daemon is replaced only once it has stopped. A
  running one is asked to stop (`daemon.stop`); while a session has a turn at work it says
  so, and this waits, asking again every two seconds, until none has. Ctrl-C while it
  waits leaves everything as it was. A daemon a TUI runs inside itself is that TUI's: it
  is left running, and what is installed is replaced under it.

  **The swap.** troupe is renamed into place: on Unix the new file replaces the old in one
  `rename`, the old one kept as `troupe.previous` by a hard link first; on Windows, where
  a running program cannot be replaced but can be renamed, the running `troupe.exe` is
  moved aside to `troupe.exe.previous` first, as `scripts/install-local.ps1` does. The
  daemon's release directory is unpacked beside the old one and renamed into its place,
  the old kept as `troupe-daemon.previous`. `--rollback` swaps each back, and run again
  swaps forward.

  **A plane's word, when signed in to one.** The caller hands over what the plane says of
  each component (`:plane`, from its `me.client_versions`, with the plane's own version
  from its discovery document). Then the version installed is the plane's `recommended`
  one rather than the latest; a version
  the plane blocks, or one older than its minimum, is never installed, whether it is the
  latest or named with `--version`. Nothing moves backwards unless the person names the
  version: a component on a blocked version whose recommended one is older is told the
  `--version` that moves it back. The release is still checked against the release key
  exactly as without a plane: a plane can hold a version back or name one, and cannot make
  this install anything the key did not sign, nor walk a machine back to an old release.

  **Every component the installers put here.** An install picks its
  components once; from then on one update moves all of them. Beside troupe and
  troupe-daemon: the desktop app, where `install.sh`/`install.ps1` put it (the AppImage
  beside the programs on Linux, `~/Applications/Troupe.app` on macOS, the per-user setup
  on Windows), replaced from the release's own AppImage, disk image or setup, held to the
  manifest as the rest; and the VS Code extension, where `code` lists it, installed again
  from the release's `troupe.vsix`. Each is replaced after troupe and troupe-daemon, and a
  failure there leaves those two in place and is said. A desktop app that is running keeps
  running the old build until it is restarted, and is told so. `--rollback` puts back the
  AppImage or the app bundle kept as `.previous`; the Windows setup and the extension keep
  no previous and are said to.
  """

  alias Troupe.Protocol.{Client, ClientUpdate, Daemon}
  alias Troupe.Release.{Keys, Manifest, Minisign}

  @repo "it-minds/troupe"
  # The VS Code extension's id, as `code --list-extensions` names it.
  @extension "objective-mj.troupe"
  # The desktop app's per-user uninstall entry on Windows, which its setup writes.
  @uninstall_key "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Troupe"
  # A manifest and its signature are a few kilobytes; anything much bigger is not one.
  @small 1_048_576
  # How many releases `--latest` looks at, newest first, before it stops looking.
  @look 20

  @type action :: :check | :update | :rollback

  @doc """
  Run one action and return the exit status.

  `opts`: `:version` (the release asked for), `:pick` (`:recommended`, the default, or
  `:latest`), `:installed` (this troupe's version), `:plane` (`%{url: plane, version:
  plane's version, versions: %{"tui" => policy, "daemon" => policy}, release_url: url}`,
  what a plane signed in to says, or `nil`), and, standing in for the machine in tests,
  `:releases` (the releases `--latest` looks at, newest first: `{:ok, [{version | nil,
  base}]}`), `:release_url`, `:repo`, `:keys`, `:target`, `:tui`, `:lib`, `:desktop` (where the
  desktop app is: `%{kind: :appimage | :mac_app | :windows_setup, path: ...}`), `:vscode`
  (VS Code's command line, or nil), `:windows?`, `:out` (a line printed), `:fetch`,
  `:run` (a program run to completion: `{:ok, output, status}`), `:daemon` (what quiets
  the daemon) and `:sleep`.
  """
  @spec run(action(), keyword()) :: non_neg_integer()
  def run(action, opts \\ []) do
    s = settings(opts)
    # Asked once: the extension's version is a program run, the desktop app's a file read.
    s = Map.put(s, :installed_now, installed(s))

    result =
      case action do
        :check -> with {:ok, s} <- planned(s), do: check(s)
        :update -> with {:ok, s} <- planned(s), do: update(s)
        :rollback -> rollback(s)
      end

    case result do
      :ok ->
        0

      {:error, why} ->
        s.out.("troupe update: " <> why)
        1
    end
  end

  @doc false
  @spec settings(keyword()) :: map()
  def settings(opts) do
    windows? = Keyword.get(opts, :windows?, match?({:win32, _}, :os.type()))

    %{
      version: opts[:version],
      # Whether the version was named by the person, who may move either way, rather than
      # chosen for them by a plane, which moves only forward but for a blocked version.
      named?: opts[:version] != nil,
      pick: Keyword.get(opts, :pick, :recommended),
      # The version the plane recommends, and how the version installed was chosen.
      recommended: nil,
      chosen: nil,
      # Where the chosen release is, when `--latest` found it somewhere of its own.
      base: nil,
      plane: opts[:plane],
      installed: opts[:installed],
      release_url: Keyword.get_lazy(opts, :release_url, fn -> env("TROUPE_RELEASE_URL") end),
      repo: Keyword.get_lazy(opts, :repo, fn -> env("TROUPE_REPO") || @repo end),
      keys: Keyword.get_lazy(opts, :keys, &Keys.trusted/0),
      target: Keyword.get_lazy(opts, :target, &Manifest.target/0),
      tui: Keyword.get_lazy(opts, :tui, fn -> tui_path(windows?) end),
      lib: Keyword.get_lazy(opts, :lib, fn -> lib_dir(windows?) end),
      desktop: Keyword.get_lazy(opts, :desktop, fn -> desktop_install(windows?) end),
      vscode: Keyword.get_lazy(opts, :vscode, fn -> code_cli(windows?) end),
      windows?: windows?,
      out: Keyword.get(opts, :out, &IO.puts/1),
      fetch: Keyword.get(opts, :fetch, &fetch/2),
      releases: Keyword.get(opts, :releases, &releases/1),
      run: Keyword.get(opts, :run, &run_program/1),
      daemon: Keyword.get(opts, :daemon, &quiet_daemon/1),
      sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
    }
  end

  defp env(name) do
    case System.get_env(name) do
      nil -> nil
      value -> if String.trim(value) == "", do: nil, else: String.trim(value)
    end
  end

  # The program that is running, when it is the binary (Burrito names it); otherwise where
  # the installers put it.
  defp tui_path(windows?) do
    exe = if windows?, do: "troupe.exe", else: "troupe"

    case env("__BURRITO_BIN_PATH") do
      nil -> Path.join(bin_dir(windows?), exe)
      path -> path
    end
  end

  defp bin_dir(windows?) do
    cond do
      dir = env("TROUPE_BIN_DIR") -> dir
      windows? -> Path.join(System.get_env("LOCALAPPDATA", ""), "Programs/troupe")
      true -> Path.join(System.user_home!(), ".local/bin")
    end
  end

  defp lib_dir(windows?) do
    cond do
      dir = env("TROUPE_LIB_DIR") -> dir
      windows? -> Path.join(System.get_env("LOCALAPPDATA", ""), "Programs/troupe-daemon")
      true -> Path.join(System.user_home!(), ".local/lib/troupe-daemon")
    end
  end

  # -- what is installed ----------------------------------------------------------

  @doc """
  The version of the troupe-daemon release in `lib`, as the installers read it, or `nil`
  when none is installed there.
  """
  @spec daemon_version(Path.t(), boolean()) :: String.t() | nil
  def daemon_version(lib, windows?) do
    if File.regular?(daemon_bin(lib, windows?)) do
      case File.read(Path.join(lib, "releases/start_erl.data")) do
        {:ok, data} -> data |> String.split() |> Enum.at(1) || "unknown version"
        {:error, _} -> "unknown version"
      end
    end
  end

  defp daemon_bin(lib, true), do: Path.join(lib, "bin/troupe-daemon.cmd")
  defp daemon_bin(lib, false), do: Path.join(lib, "bin/troupe-daemon")

  defp installed(%{installed_now: %{} = inst}), do: inst

  defp installed(s) do
    %{
      tui: if(File.regular?(s.tui), do: s.installed || "unknown version"),
      daemon: daemon_version(s.lib, s.windows?),
      desktop: desktop_version(s.desktop, s),
      vscode: extension_version(s.vscode, s)
    }
  end

  # -- the desktop app and the VS Code extension ----------------------------------

  # Where the installers put the desktop app: `install.sh` puts the AppImage beside the
  # programs and the app bundle under `~/Applications`; `install.ps1` runs the per-user
  # setup, whose uninstall entry is what says it is there and which version.
  defp desktop_install(true), do: %{kind: :windows_setup, path: nil}

  defp desktop_install(false) do
    case :os.type() do
      {:unix, :darwin} ->
        %{kind: :mac_app, path: Path.join(System.user_home!(), "Applications/Troupe.app")}

      _ ->
        %{
          kind: :appimage,
          path: Path.join(bin_dir(false), "troupe-desktop"),
          entry: Path.join(data_dir(), "applications/troupe.desktop")
        }
    end
  end

  defp data_dir, do: env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share")

  @doc """
  The version of the desktop app the installers put here, or `nil` where there is none:
  the AppImage's from the `.version` file beside it or the menu entry's comment, the app
  bundle's from its `Info.plist`, the Windows setup's from its uninstall entry.
  """
  @spec desktop_version(map() | nil, map()) :: String.t() | nil
  def desktop_version(%{kind: :appimage, path: path} = desktop, _s) do
    if File.regular?(path) do
      case File.read(path <> ".version") do
        {:ok, version} when byte_size(version) > 0 -> String.trim(version)
        _ -> entry_version(desktop[:entry]) || "unknown version"
      end
    end
  end

  def desktop_version(%{kind: :mac_app, path: app}, _s) do
    plist = Path.join(app, "Contents/Info.plist")

    if File.regular?(plist) do
      case Regex.run(
             ~r{<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>},
             File.read!(plist)
           ) do
        [_, version] -> String.trim(version)
        _ -> "unknown version"
      end
    end
  end

  def desktop_version(%{kind: :windows_setup}, s) do
    case s.run.(["reg", "query", @uninstall_key, "/v", "DisplayVersion"]) do
      {:ok, output, 0} ->
        case Regex.run(~r/DisplayVersion\s+REG_SZ\s+(\S+)/, output) do
          [_, version] -> version
          _ -> "unknown version"
        end

      _ ->
        nil
    end
  end

  def desktop_version(_none, _s), do: nil

  # `Comment=The Troupe desktop app, release 0.28.0-beta`, as the installer writes the entry.
  defp entry_version(nil), do: nil

  defp entry_version(entry) do
    with {:ok, text} <- File.read(entry),
         [_, version] <- Regex.run(~r/^Comment=.*\brelease (\S+)\s*$/m, text) do
      version
    else
      _ -> nil
    end
  end

  # VS Code's command line, as the installers find it: `TROUPE_VSCODE_CLI`, `code` on the
  # PATH, or where the macOS and Windows setups put it.
  defp code_cli(windows?) do
    local = System.get_env("LOCALAPPDATA", "")
    programs = System.get_env("ProgramFiles", "")

    candidates =
      if windows? do
        [
          env("TROUPE_VSCODE_CLI"),
          Troupe.Executable.find("code.cmd"),
          Path.join(local, "Programs/Microsoft VS Code/bin/code.cmd"),
          Path.join(programs, "Microsoft VS Code/bin/code.cmd")
        ]
      else
        [
          env("TROUPE_VSCODE_CLI"),
          Troupe.Executable.find("code"),
          "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code",
          Path.join(
            System.user_home!(),
            "Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
          )
        ]
      end

    Enum.find(candidates, &(is_binary(&1) and &1 != "" and File.regular?(&1)))
  end

  @doc """
  The version of the VS Code extension `code` lists, or `nil` where there is no `code` or
  it is not installed.
  """
  @spec extension_version(String.t() | nil, map()) :: String.t() | nil
  def extension_version(nil, _s), do: nil

  def extension_version(code, s) do
    case s.run.([code, "--list-extensions", "--show-versions"]) do
      {:ok, output, 0} -> output |> String.split("\n") |> Enum.find_value(&extension_line/1)
      _ -> nil
    end
  end

  # `objective-mj.troupe@0.29.0`, the line `code` lists the extension on.
  defp extension_line(line) do
    case line |> String.trim() |> String.split("@") do
      [id, version] -> if String.downcase(id) == @extension, do: version
      _ -> nil
    end
  end

  # A program run to completion, under the reaper as every OS process is.
  defp run_program([program | args] = argv) do
    case Troupe.Reaper.run(File.cwd!(), argv, timeout_ms: 600_000) do
      {:ok, output, status} when is_integer(status) ->
        {:ok, output, status}

      {:ok, _output, :timeout} ->
        {:error, "#{program} did not finish"}

      {:error, reason} ->
        {:error, "#{program} #{Enum.join(args, " ")}: #{Troupe.Reaper.explain(reason)}"}
    end
  end

  # The desktop app's version drops the pre-release part (`scripts/version.exs`), so the
  # release's desktop app is numbered after the version before its first dash.
  defp to_version("desktop", version), do: version |> String.split("-") |> hd()
  defp to_version(_component, version), do: version

  # -- --check ------------------------------------------------------------------

  defp check(s) do
    Enum.each(installed_lines(installed(s), s), s.out)
    if s.plane, do: s.out.("  plane          #{s.plane.url} #{plane_says(s)}")

    with {:ok, rel} <- release(s) do
      s.out.("  release        #{rel.version}  #{rel.base}")
      s.out.("                 manifest signed by release key #{Enum.join(rel.key_ids, " and ")}")
      if line = chosen_line(rel, s), do: s.out.("                 " <> line)

      case plan(rel, s) do
        {:ok, %{steps: []}} ->
          s.out.("Nothing to update: what is installed is #{rel.version} or newer.")

        {:ok, %{steps: steps}} ->
          names = Enum.map_join(steps, " and ", &"#{&1.name} #{&1.from}")
          s.out.("troupe update would install #{rel.version} over #{names}.")

        {:error, why} ->
          s.out.("troupe update would install nothing: #{why}")
      end

      :ok
    end
  end

  # What is installed, one line each: the version or "not installed", and where.
  defp installed_lines(inst, s) do
    [
      "  troupe         #{inst.tui || "not installed"}  #{s.tui}",
      "  troupe-daemon  #{inst.daemon || "not installed"}  #{s.lib}",
      "  the desktop app  #{inst.desktop || "not installed"}  #{desktop_where(s)}",
      "  the VS Code extension  #{inst.vscode || "not installed"}  #{s.vscode || "no code command line"}"
    ]
  end

  # -- the release ----------------------------------------------------------------

  @doc false
  @spec release(map()) :: {:ok, map()} | {:error, String.t()}
  def release(s) do
    with {:ok, base, tag} <- source(s),
         {:ok, rel} <- release_at(s, base, s.version, tag),
         :ok <- served(rel.version, s) do
      {:ok, rel}
    end
  end

  # A release's manifest at `base`, once its signature holds and it names what was asked.
  defp release_at(s, base, asked, tag) do
    with {:ok, bytes} <- get_small(s, base, "manifest.json"),
         {:ok, signature} <- get_small(s, base, "manifest.json.minisig"),
         {:ok, signed} <- signed(bytes, signature, s.keys, base),
         {:ok, manifest} <- decoded(bytes, base),
         :ok <- asked_for(manifest, asked, tag, base) do
      {:ok, %{version: manifest.version, base: base, manifest: manifest, key_ids: signed.key_ids}}
    end
  end

  # Where `--latest` found the release it chose.
  defp source(%{base: base, version: version}) when is_binary(base), do: {:ok, base, version}

  defp source(%{release_url: url}) when is_binary(url),
    do: {:ok, String.trim_trailing(url, "/"), nil}

  # Where the plane signed in to says releases are (#657): its own `/downloads`, or a
  # mirror laid out as GitHub's, each release under `v<version>`. There is no "latest"
  # there to be redirected to, so the version is the plane's recommended one or the one
  # named.
  defp source(%{plane: %{release_url: url}, version: version})
       when is_binary(url) and is_binary(version),
       do: {:ok, String.trim_trailing(url, "/") <> "/v#{version}", version}

  defp source(%{plane: %{release_url: url} = plane}) when is_binary(url),
    do:
      {:error,
       "the plane at #{plane.url} has releases at #{url} and recommends no version: " <>
         "name one with troupe update --version X"}

  defp source(%{version: version, repo: repo}) when is_binary(version),
    do: {:ok, "https://github.com/#{repo}/releases/download/v#{version}", version}

  defp source(%{repo: repo}) do
    url = "https://github.com/#{repo}/releases/latest"

    case Req.get(url, redirect: false, retry: false, receive_timeout: 30_000) do
      {:ok, %Req.Response{status: status} = resp} when status in 300..399 ->
        case latest_tag(List.first(Req.Response.get_header(resp, "location")) || "") do
          nil -> {:error, "#{url} did not name a release"}
          version -> {:ok, "https://github.com/#{repo}/releases/download/v#{version}", version}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error,
         "#{url} answered #{status}, not the latest release (set TROUPE_RELEASE_URL to a mirror)"}

      {:error, exception} ->
        {:error, "could not reach #{url}: #{Exception.message(exception)}"}
    end
  end

  # The releases `--latest` looks at, newest first, each `{version, base}`: the one
  # `TROUPE_RELEASE_URL` names, whose version its manifest says; GitHub's list otherwise,
  # drafts left out and pre-releases in, since a beta is published as one. A plane's own
  # mirror is found by version and lists none.
  defp releases(%{release_url: url}) when is_binary(url),
    do: {:ok, [{nil, String.trim_trailing(url, "/")}]}

  defp releases(%{plane: %{release_url: url} = plane}) when is_binary(url),
    do:
      {:error,
       "the plane at #{plane.url} has releases at #{url}, which lists none to choose the newest " <>
         "from: name one with troupe update --version X"}

  defp releases(%{repo: repo}) do
    url = "https://api.github.com/repos/#{repo}/releases?per_page=#{@look + 10}"

    case Req.get(url,
           retry: false,
           receive_timeout: 30_000,
           headers: [accept: "application/json"]
         ) do
      {:ok, %Req.Response{status: 200, body: list}} when is_list(list) ->
        {:ok,
         list
         |> Enum.reject(&(&1["draft"] == true))
         |> Enum.flat_map(&listed_version/1)
         |> Enum.sort_by(&elem(&1, 1), &newest_first/2)
         |> Enum.map(fn {version, _parsed} ->
           {version, "https://github.com/#{repo}/releases/download/v#{version}"}
         end)}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         "#{url} answered #{status}, not the list of releases (set TROUPE_RELEASE_URL to a mirror)"}

      {:error, exception} ->
        {:error, "could not reach #{url}: #{Exception.message(exception)}"}
    end
  end

  defp listed_version(%{"tag_name" => "v" <> version}) do
    case Version.parse(version) do
      {:ok, parsed} -> [{version, parsed}]
      :error -> []
    end
  end

  defp listed_version(_release), do: []

  defp newest_first(a, b), do: Version.compare(a, b) != :lt

  @doc false
  @spec latest_tag(String.t()) :: String.t() | nil
  def latest_tag(location) do
    case Regex.run(~r{/releases/tag/v([^/?#]+)\z}, location) do
      [_, version] -> URI.decode(version)
      nil -> nil
    end
  end

  defp get_small(s, base, name) do
    url = base <> "/" <> name

    case s.fetch.(url, :binary) do
      {:ok, bytes} when byte_size(bytes) <= @small ->
        {:ok, bytes}

      {:ok, _big} ->
        {:error, "#{url} is too big to be a release's #{name}; nothing is installed"}

      {:error, :not_found} when name == "manifest.json" ->
        {:error,
         "the release at #{base} has no manifest.json: releases from before 0.13 and pre-releases " <>
           "are not signed, and troupe update installs nothing it cannot check"}

      {:error, :not_found} ->
        {:error,
         "the release at #{base} has a manifest.json but no #{name}: nothing unsigned is installed"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp signed(bytes, signature, keys, base) do
    case Minisign.verify(bytes, signature, keys) do
      {:ok, signed} ->
        {:ok, signed}

      {:error, why} ->
        {:error, "the manifest of the release at #{base} #{why}; nothing is installed"}
    end
  end

  defp decoded(bytes, base) do
    case Manifest.decode(bytes) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, why} -> {:error, "the signed manifest at #{base} #{why}; nothing is installed"}
    end
  end

  # An old signed manifest served in place of the one asked for is still signed: what it
  # names has to be what was asked for.
  defp asked_for(%{version: version}, asked, tag, base) do
    cond do
      asked && version != asked ->
        {:error, "the release at #{base} is #{version}, not #{asked}; nothing is installed"}

      tag && version != tag ->
        {:error,
         "the release tagged v#{tag} carries the manifest of #{version}; nothing is installed"}

      true ->
        :ok
    end
  end

  # -- a plane's word ---------------------------------------------------------------

  # With a plane and no version named, the one asked for is the plane's recommended
  # version: the terminal's, where troupe is installed and the plane names one, and
  # otherwise the daemon's. With none, the latest, as without a plane. `--latest` looks
  # past it for a newer release that supports the plane; a version named is the person's.
  defp planned(s) do
    s = %{s | recommended: recommended(s)}

    cond do
      s.named? -> {:ok, s}
      s.pick == :latest -> latest(s)
      true -> {:ok, %{s | version: s.recommended || s.version, chosen: :recommended}}
    end
  end

  defp recommended(%{plane: %{} = plane} = s) do
    components =
      if installed(s).tui, do: ["tui", "daemon", "desktop"], else: ["daemon", "tui", "desktop"]

    Enum.find_value(components, &policy(plane, &1)["recommended"])
  end

  defp recommended(_s), do: nil

  defp plane_says(%{recommended: version}) when is_binary(version),
    do: "recommends #{version}"

  defp plane_says(_s), do: "recommends no version"

  # How the version installed was chosen, as `troupe update` says it.
  defp chosen_line(rel, %{chosen: :recommended, plane: %{url: url}, recommended: version})
       when is_binary(version),
       do: "#{rel.version}, the version #{url} recommends"

  defp chosen_line(rel, %{chosen: :latest, plane: %{url: url}} = s),
    do:
      "#{rel.version}, the newest release that supports #{url} " <>
        "(it #{plane_says(s)})"

  defp chosen_line(rel, %{chosen: :latest}), do: "#{rel.version}, the newest release"

  defp chosen_line(rel, %{chosen: {:fallback, why}, plane: %{url: url}}) do
    unknown =
      if rel.manifest.supports == nil,
        do: "; it says nothing of which planes it supports, and the plane's word covers it",
        else: ""

    "#{rel.version}, the version #{url} recommends: #{why}" <> unknown
  end

  defp chosen_line(_rel, _s), do: nil

  # -- --latest ---------------------------------------------------------------------

  # The newest release that supports the plane and that the plane serves, looked for
  # newest first and never past the recommended version: from there on the plane's word
  # is the better one. A release that says nothing of planes is passed over, said; one
  # below the plane's minimum ends the look, since every older one is too.
  defp latest(s) do
    if s.plane && not is_binary(s.plane[:version]),
      do:
        fall_back(
          s,
          "the plane at #{s.plane.url} does not say which version it is, so no release can be " <>
            "said to support it"
        ),
      else: look_for_latest(s)
  end

  defp look_for_latest(s) do
    with {:ok, listed} <- s.releases.(s) do
      case look(Enum.take(listed, @look), s) do
        {:found, rel} ->
          {:ok, %{s | version: rel.version, base: rel.base, chosen: :latest}}

        :reached ->
          fall_back(s, "no newer release says it supports this plane")

        {:stopped, why} ->
          fall_back(s, why)

        :none when length(listed) > @look ->
          fall_back(
            s,
            "none of the #{@look} newest releases says it supports this plane, and troupe " <>
              "update looked no further"
          )

        :none ->
          fall_back(
            s,
            "none of the #{length(listed)} releases listed says it supports this plane"
          )
      end
    end
  end

  defp fall_back(%{recommended: version} = s, why) when is_binary(version),
    do: {:ok, %{s | version: version, chosen: {:fallback, why}}}

  defp fall_back(%{plane: %{url: url}}, why),
    do:
      {:error,
       "troupe update --latest found nothing to install for the plane at #{url}, which " <>
         "recommends no version: #{why}; name one with troupe update --version X"}

  defp fall_back(_s, why), do: {:error, "troupe update --latest found nothing to install: #{why}"}

  defp look(listed, s), do: Enum.reduce_while(listed, :none, &look_at(&1, &2, s))

  defp look_at({tag, base}, :none, s) do
    with true <- tag == nil or past_recommended?(tag, s),
         {:ok, rel} <- release_at(s, base, nil, tag) do
      fits(rel, s)
    else
      false ->
        {:halt, :reached}

      {:error, why} ->
        passed_over(s, tag || base, why)
        {:cont, :none}
    end
  end

  defp fits(rel, s) do
    cond do
      not past_recommended?(rel.version, s) ->
        {:halt, :reached}

      s.plane == nil ->
        {:halt, {:found, rel}}

      true ->
        case {Manifest.supports?(rel.manifest, s.plane[:version]), judged(rel.version, s)} do
          {_supports, {:below_minimum, why}} ->
            {:halt, {:stopped, why}}

          {_supports, {:blocked, why}} ->
            passed_over(s, rel.version, why)
            {:cont, :none}

          {true, :ok} ->
            {:halt, {:found, rel}}

          {false, :ok} ->
            passed_over(
              s,
              rel.version,
              "it supports planes #{rel.manifest.supports.plane}, and the plane at " <>
                "#{s.plane.url} is #{s.plane[:version]}"
            )

            {:cont, :none}

          {:unknown, :ok} ->
            passed_over(
              s,
              rel.version,
              "its manifest says nothing of which planes it supports, from before releases said so"
            )

            {:cont, :none}
        end
    end
  end

  defp past_recommended?(version, %{recommended: recommended}) when is_binary(recommended),
    do: version != recommended and not ClientUpdate.older?(version, recommended)

  defp past_recommended?(_version, _s), do: true

  defp passed_over(s, what, why), do: s.out.("  passed over #{what}: #{why}")

  @doc """
  What `troupe doctor` says of updates, signed in to a plane that recommends a version
  while a newer release than it, and than this troupe, supports the plane and is served:
  one line, never a failure. `nil` otherwise, or where the releases cannot be asked.
  Takes `run/2`'s options.
  """
  @spec doctor_check(keyword()) :: %{name: String.t(), state: :ok, detail: String.t()} | nil
  def doctor_check(opts) do
    s = settings(Keyword.merge(opts, pick: :latest, version: nil, out: fn _line -> :ok end))
    s = Map.put(s, :installed_now, installed(s))

    with %{} <- s.plane,
         {:ok, %{chosen: :latest, version: version, recommended: recommended}}
         when is_binary(recommended) <- planned(s),
         true <-
           s.installed in [nil, "unknown version"] or ClientUpdate.older?(s.installed, version) do
      %{
        name: "update",
        state: :ok,
        detail: "#{version} supports this plane; `troupe update --latest` installs it"
      }
    else
      _nothing_newer -> nil
    end
  end

  defp policy(%{versions: versions}, component) when is_map(versions) do
    case versions[component] do
      %{} = policy -> policy
      _none -> %{}
    end
  end

  defp policy(_plane, _component), do: %{}

  # A version the plane serves to each component this would replace: none blocked, none
  # older than its minimum. Without a plane, every signed version is.
  defp served(version, s) do
    case judged(version, s) do
      :ok -> :ok
      {_why, sentence} -> {:error, sentence <> "; nothing is installed"}
    end
  end

  defp judged(_version, %{plane: nil}), do: :ok

  defp judged(version, %{plane: plane} = s) do
    inst = installed(s)

    [{"tui", inst.tui}, {"daemon", inst.daemon}, {"desktop", inst.desktop}]
    |> Enum.reject(fn {_component, from} -> is_nil(from) end)
    |> Enum.reduce_while(:ok, fn {component, _from}, :ok ->
      policy = policy(plane, component)
      name = ClientUpdate.program(component)

      case ClientUpdate.judge(policy, version) do
        {:refuse, :blocked} ->
          {:halt, {:blocked, "the plane at #{plane.url} blocks #{name} #{version}"}}

        {:refuse, :below_minimum} ->
          {:halt,
           {:below_minimum,
            "#{version} is older than the oldest #{name} the plane at #{plane.url} serves " <>
              "(#{policy["minimum"]})"}}

        {:ok, _action} ->
          {:cont, :ok}
      end
    end)
  end

  # A component on a version the plane blocks, which the release would not replace because
  # it is no newer: moving back is the person's to ask for by name, never the plane's to
  # decide, so a plane cannot walk a fleet back to an old release of its choosing.
  defp held_back(steps_from, rel, %{plane: %{} = plane, named?: false}) do
    Enum.find_value(steps_from, :ok, fn {name, component, from} ->
      if from in List.wrap(policy(plane, component)["blocked"]) and
           not wanted?(from, rel.version, false) do
        {:error,
         "the plane at #{plane.url} blocks #{name} #{from}, and the version it recommends, " <>
           "#{rel.version}, is older: troupe update --version #{rel.version} moves back to it"}
      end
    end)
  end

  defp held_back(_steps_from, _rel, _s), do: :ok

  # -- the plan -----------------------------------------------------------------

  defp plan(rel, s) do
    inst = installed(s)

    candidates =
      Enum.reject(
        [
          {"troupe-daemon", "daemon", inst.daemon},
          {"troupe", "tui", inst.tui},
          {"the desktop app", "desktop", inst.desktop},
          {"the VS Code extension", "vscode", inst.vscode}
        ],
        &is_nil(elem(&1, 2))
      )

    cond do
      candidates == [] ->
        {:error,
         "no troupe at #{s.tui}, no troupe-daemon in #{s.lib}, no desktop app and no VS Code " <>
           "extension: troupe update replaces what the installers put there"}

      s.target == nil ->
        {:error, "this machine is not one a release is built for"}

      true ->
        with :ok <- held_back(candidates, rel, s), do: steps(candidates, rel, s)
    end
  end

  defp steps(candidates, rel, s) do
    candidates
    |> Enum.filter(fn {_name, component, from} ->
      wanted?(from, to_version(component, rel.version), s.named?)
    end)
    |> Enum.reduce_while({:ok, []}, &add_step(&1, &2, rel, s))
    |> case do
      {:ok, steps} -> {:ok, %{steps: steps, version: rel.version}}
      error -> error
    end
  end

  # troupe and troupe-daemon a release lacks for this machine stop the update; the desktop
  # app and the extension are extras, left as they are and said.
  defp add_step({name, component, from}, {:ok, steps}, rel, s) do
    case artifact(rel, component, s) do
      nil when component in ["tui", "daemon"] ->
        {:halt, {:error, "release #{rel.version} has no #{name} for #{s.target}"}}

      nil ->
        s.out.(
          "  #{name} #{from} is left as it is: release #{rel.version} has none for this computer"
        )

        {:cont, {:ok, steps}}

      artifact ->
        step = %{name: name, component: component, from: from, artifact: artifact}
        {:cont, {:ok, steps ++ [step]}}
    end
  end

  # The desktop app's files are named by the installers' kind: the AppImage, the disk
  # image or the setup, never the updater's bundle beside them; the extension's is one.
  defp artifact(rel, "desktop", s) do
    {target, suffix} =
      case s.desktop[:kind] do
        :appimage -> {"linux_x86_64", ".AppImage"}
        :mac_app -> {"macos_universal", ".dmg"}
        :windows_setup -> {"windows_x86_64", "-setup.exe"}
      end

    Enum.find(
      rel.manifest.artifacts,
      &(&1.component == "desktop" and &1.target == target and String.ends_with?(&1.file, suffix))
    )
  end

  defp artifact(rel, "vscode", _s), do: Manifest.find(rel.manifest, "vscode", nil)
  defp artifact(rel, component, s), do: Manifest.find(rel.manifest, component, s.target)

  # The latest release replaces only what is older; a version asked for by name replaces
  # whatever is not it, older or newer.
  defp wanted?(same, same, _named?), do: false
  defp wanted?(_from, _to, true), do: true

  defp wanted?(from, to, false) do
    case {Version.parse(from), Version.parse(to)} do
      {{:ok, from}, {:ok, to}} -> Version.compare(from, to) == :lt
      _unparsed -> true
    end
  end

  # -- the update ---------------------------------------------------------------

  defp update(s) do
    with {:ok, rel} <- release(s),
         {:ok, plan} <- plan(rel, s) do
      s.out.(
        "release #{rel.version} (#{rel.base}), manifest signed by release key #{Enum.join(rel.key_ids, " and ")}"
      )

      announce(rel, s)

      if plan.steps == [] do
        s.out.("Nothing to update: what is installed is #{rel.version} or newer.")
        :ok
      else
        install(plan, rel, s)
      end
    end
  end

  # How the release was chosen, or what the plane says where that is all there is to say.
  defp announce(rel, s) do
    case chosen_line(rel, s) do
      nil -> if s.plane, do: s.out.("the plane at #{s.plane.url} #{plane_says(s)}")
      line -> s.out.(line)
    end
  end

  # troupe and troupe-daemon first, together, as before; then each extra on its own. An
  # extra that fails leaves the two in place and is said, since it is not theirs to undo.
  defp install(plan, rel, s) do
    Enum.each(
      plan.steps,
      &s.out.("  #{&1.name}  #{&1.from} -> #{to_version(&1.component, rel.version)}")
    )

    {core, extras} = Enum.split_with(plan.steps, &(&1.component in ["tui", "daemon"]))

    with {:ok, staged} <- download(plan.steps, rel, s),
         :ok <- quiet(staged, s),
         :ok <- swap_in(Enum.filter(staged, &(&1 in core)), s) do
      Enum.each(core, fn step -> s.out.(installed_line(step, rel.version, s)) end)
      failed = Enum.reject(extras, &install_extra(&1, rel, s))
      clean_staging(extras, s)

      if failed == [] do
        s.out.("Done. troupe update --rollback puts what was there before back.")
        :ok
      else
        {:error,
         Enum.map_join(failed, "; ", &"#{&1.name} was not replaced") <> "; the rest is installed"}
      end
    else
      {:error, why} ->
        clean_staging(plan.steps, s)
        {:error, why}
    end
  end

  defp install_extra(step, rel, s) do
    case swap_extra_in(step, s) do
      :ok ->
        s.out.(installed_line(step, rel.version, s))
        true

      {:error, why} ->
        s.out.("#{step.name} #{step.from} is left as it is: #{why}")
        false
    end
  end

  defp installed_line(%{component: "daemon", from: from}, version, s),
    do:
      "troupe-daemon #{version} is in #{s.lib} (#{from} kept as #{Path.basename(s.lib)}.previous)"

  defp installed_line(%{component: "tui", from: from}, version, s),
    do: "troupe #{version} is #{s.tui} (#{from} kept as #{Path.basename(s.tui)}.previous)"

  defp installed_line(%{component: "desktop", from: from}, version, %{
         desktop: %{kind: :windows_setup}
       }),
       do:
         "the desktop app #{to_version("desktop", version)} is set up (#{from} before; its setup keeps no previous)"

  defp installed_line(%{component: "desktop", from: from}, version, s),
    do:
      "the desktop app #{to_version("desktop", version)} is #{s.desktop.path} (#{from} kept as " <>
        "#{Path.basename(s.desktop.path)}.previous); one that is running keeps the old build until it is restarted"

  defp installed_line(%{component: "vscode", from: from}, version, s),
    do:
      "the VS Code extension #{version} is installed with #{s.vscode} (#{from} before; open windows take it when VS Code restarts)"

  defp download(steps, rel, s) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, staged} ->
      dest = download_path(step, s)
      url = rel.base <> "/" <> step.artifact.file
      _ = File.rm(dest)

      with :ok <- s.fetch.(url, dest),
           :ok <- Manifest.check_file(step.artifact, dest),
           :ok <- prepare(step, dest, s) do
        s.out.("  #{step.artifact.file}: #{step.artifact.size} bytes, sha256 as signed")
        {:cont, {:ok, staged ++ [step]}}
      else
        {:error, :not_found} ->
          {:halt,
           {:error,
            "#{url} is not there, though the signed manifest names it; nothing is installed"}}

        {:error, why} ->
          {:halt, {:error, "#{why}; nothing is installed"}}
      end
    end)
  end

  defp download_path(%{component: "daemon"}, s), do: s.lib <> ".new.tar.gz"
  defp download_path(%{component: "tui"}, s), do: s.tui <> ".new"

  defp download_path(%{component: "desktop"}, %{desktop: %{kind: :appimage, path: path}}),
    do: path <> ".new"

  defp download_path(%{component: "desktop"}, %{desktop: %{kind: :mac_app, path: app}}),
    do: app <> ".new.dmg"

  defp download_path(%{component: "desktop", artifact: %{file: file}}, _s),
    do: Path.join(System.tmp_dir!(), file)

  defp download_path(%{component: "vscode", artifact: %{file: file}}, _s),
    do: Path.join(System.tmp_dir!(), "troupe-update-" <> file)

  # The daemon's archive unpacked beside the release it replaces, and checked to be one;
  # the TUI made executable. Nothing in place is touched yet.
  defp prepare(%{component: "daemon"}, archive, s) do
    staging = s.lib <> ".new"
    _ = File.rm_rf(staging)
    File.mkdir_p!(staging)

    result =
      case :erl_tar.extract(String.to_charlist(archive), [
             :compressed,
             {:cwd, String.to_charlist(staging)}
           ]) do
        :ok ->
          if File.regular?(daemon_bin(staging, s.windows?)),
            do: :ok,
            else:
              {:error,
               "#{Path.basename(archive)} holds no #{Path.relative_to(daemon_bin(staging, s.windows?), staging)}"}

        {:error, reason} ->
          {:error, "could not unpack the daemon's release: #{inspect(reason)}"}
      end

    _ = File.rm(archive)
    result
  end

  defp prepare(%{component: "tui"}, path, s) do
    if s.windows?, do: :ok, else: File.chmod(path, 0o755)
  end

  defp prepare(%{component: "desktop"}, path, %{desktop: %{kind: :appimage}}),
    do: File.chmod(path, 0o755)

  defp prepare(_extra, _path, _s), do: :ok

  defp clean_staging(steps, s) do
    for step <- steps do
      _ = File.rm(download_path(step, s))
      if step.component == "daemon", do: File.rm_rf(s.lib <> ".new")

      if step.component == "desktop" and s.desktop[:kind] == :mac_app,
        do: File.rm_rf(s.desktop.path <> ".new")
    end

    :ok
  end

  # -- the extras swapped in -------------------------------------------------------

  # The AppImage as troupe is: the old one kept beside it, the new renamed into place in
  # one step, and its version written beside it and into the menu entry's comment.
  defp swap_extra_in(
         %{component: "desktop", artifact: artifact} = step,
         %{desktop: %{kind: :appimage, path: path}} = s
       ) do
    previous = path <> ".previous"
    _ = File.rm(previous)

    with :ok <- link_or_copy(path, previous),
         :ok <-
           rename(
             download_path(step, s),
             path,
             s,
             "the new desktop app could not be moved into #{path}"
           ) do
      version = to_version("desktop", artifact_version(artifact))
      _ = File.write(previous <> ".version", (step.from || "unknown version") <> "\n")
      _ = File.write(path <> ".version", version <> "\n")
      _ = stamp_entry(s.desktop[:entry], version)
      :ok
    end
  end

  # The disk image opened, its app copied beside the one it replaces, which is kept as
  # `.previous`, and the copy renamed into place; the image is let go of either way.
  defp swap_extra_in(%{component: "desktop"} = step, %{desktop: %{kind: :mac_app, path: app}} = s) do
    dmg = download_path(step, s)
    mount = app <> ".new.mount"
    staging = app <> ".new"
    _ = File.rm_rf(staging)
    File.mkdir_p!(mount)

    result =
      with {:ok, _out, 0} <-
             s.run.([
               "hdiutil",
               "attach",
               "-nobrowse",
               "-readonly",
               "-quiet",
               "-mountpoint",
               mount,
               dmg
             ]),
           {:ok, bundle} <- bundle_in(mount, dmg),
           {:ok, _} <- File.cp_r(bundle, staging) do
        :ok
      else
        {:ok, output, status} ->
          {:error,
           "hdiutil could not open #{Path.basename(dmg)} (#{status}): #{String.trim(output)}"}

        {:error, reason, _file} ->
          {:error, "#{dmg} could not be copied: #{:file.format_error(reason)}"}

        {:error, why} when is_binary(why) ->
          {:error, why}

        {:error, reason} ->
          {:error, "#{dmg} could not be copied: #{inspect(reason)}"}
      end

    _ = s.run.(["hdiutil", "detach", "-quiet", mount])
    _ = File.rmdir(mount)

    with :ok <- result,
         :ok <- remove_dir(app <> ".previous"),
         :ok <- rename(app, app <> ".previous", s, "#{app} could not be moved aside") do
      staging
      |> rename(app, s, "the new desktop app could not be moved into #{app}")
      |> undoing(fn -> File.rename(app <> ".previous", app) end)
    end
  end

  # The release's setup, run silently as the installer runs it: per user, replacing the
  # one there, closing a running app itself.
  defp swap_extra_in(%{component: "desktop"} = step, %{desktop: %{kind: :windows_setup}} = s) do
    setup = download_path(step, s)

    case s.run.([setup, "/S"]) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error,
         "#{Path.basename(setup)} exited with #{status}#{said(output)}; close Troupe if it is running and run troupe update again"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp swap_extra_in(%{component: "vscode"} = step, s) do
    vsix = download_path(step, s)

    case s.run.([s.vscode, "--install-extension", vsix, "--force"]) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, status} ->
        {:error, "#{s.vscode} --install-extension exited with #{status}#{said(output)}"}

      {:error, why} ->
        {:error, why}
    end
  end

  defp said(output) do
    case String.trim(output) do
      "" -> ""
      text -> " (#{text |> String.split("\n") |> List.last()})"
    end
  end

  defp bundle_in(mount, dmg) do
    case mount |> File.ls() |> elem(1) |> Enum.find(&String.ends_with?(&1, ".app")) do
      nil -> {:error, "#{Path.basename(dmg)} contains no .app"}
      name -> {:ok, Path.join(mount, name)}
    end
  end

  defp artifact_version(%{file: file}) do
    case Regex.run(~r/_(\d+\.\d+\.\d+[^_]*)_/, file) do
      [_, version] -> version
      _ -> "unknown version"
    end
  end

  # `Comment=The Troupe desktop app, release X`: the line the installer wrote, kept true.
  defp stamp_entry(nil, _version), do: :ok

  defp stamp_entry(entry, version) do
    with {:ok, text} <- File.read(entry) do
      File.write(entry, Regex.replace(~r/^(Comment=.*\brelease )\S+/m, text, "\\g{1}#{version}"))
    end
  end

  defp desktop_where(%{desktop: %{kind: :windows_setup}}),
    do: "the per-user setup (Settings > Apps)"

  defp desktop_where(%{desktop: %{path: path}}) when is_binary(path), do: path
  defp desktop_where(_s), do: "nowhere"

  defp quiet(steps, s) do
    if Enum.any?(steps, &(&1.component == "daemon")), do: s.daemon.(s), else: :ok
  end

  # The daemon first: when troupe cannot follow it, the daemon goes back as it was.
  defp swap_in(steps, s) do
    components = Enum.map(steps, & &1.component)
    daemon? = "daemon" in components

    with :ok <- swap_daemon_in(daemon?, s) do
      ("tui" in components)
      |> swap_tui_in(s)
      |> undoing(fn -> undo_daemon(daemon?, s) end)
    end
  end

  defp swap_daemon_in(false, _s), do: :ok

  defp swap_daemon_in(true, %{lib: lib} = s) do
    previous = lib <> ".previous"
    aside = "#{lib} could not be moved aside: something still runs from it"

    with :ok <- remove_dir(previous),
         :ok <- rename(lib, previous, s, aside) do
      (lib <> ".new")
      |> rename(lib, s, "the new troupe-daemon could not be moved into #{lib}")
      |> undoing(fn -> File.rename(previous, lib) end)
    end
  end

  defp undo_daemon(false, _s), do: :ok

  defp undo_daemon(true, %{lib: lib}) do
    _ = File.rename(lib, lib <> ".new")
    _ = File.rename(lib <> ".previous", lib)
    :ok
  end

  defp swap_tui_in(false, _s), do: :ok

  defp swap_tui_in(true, %{tui: tui} = s) do
    previous = tui <> ".previous"
    clear_set_aside(tui)

    with :ok <- remove_or_set_aside(previous),
         :ok <- keep(tui, previous, s) do
      (tui <> ".new")
      |> rename(tui, s, "the new troupe could not be moved into #{tui}")
      |> undoing(fn -> unkeep(previous, tui, s) end)
    end
  end

  # The old troupe back where it was: on Windows it was moved aside; on Unix it never left.
  defp unkeep(previous, tui, %{windows?: true}), do: File.rename(previous, tui)
  defp unkeep(_previous, _tui, _s), do: :ok

  # `result`, after `undo` when it is an error.
  defp undoing(:ok, _undo), do: :ok

  defp undoing({:error, _why} = error, undo) do
    _ = undo.()
    error
  end

  # Unix keeps the old file by a second name, so the rename that follows replaces the
  # program in one step; Windows cannot replace a running program, so it is renamed aside.
  defp keep(tui, previous, %{windows?: true} = s),
    do: rename(tui, previous, s, "#{tui} could not be moved aside")

  defp keep(tui, previous, _s) do
    case File.ln(tui, previous) do
      :ok ->
        :ok

      {:error, _no_link} ->
        case File.cp(tui, previous) do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "#{tui} could not be kept as #{previous}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp remove_dir(path) do
    case File.rm_rf(path) do
      {:ok, _} ->
        :ok

      {:error, _reason, _file} ->
        {:error, "#{path} could not be removed: something still runs from it"}
    end
  end

  # A previous troupe a terminal still runs cannot be deleted on Windows, but can be
  # renamed: set aside, for a later update to remove once it is free.
  defp remove_or_set_aside(path) do
    cond do
      not File.exists?(path) ->
        :ok

      File.rm(path) == :ok ->
        :ok

      true ->
        stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")

        case File.rename(path, "#{path}.in-use-#{stamp}") do
          :ok ->
            :ok

          {:error, reason} ->
            {:error, "#{path} could not be removed or set aside: #{:file.format_error(reason)}"}
        end
    end
  end

  defp clear_set_aside(tui) do
    dir = Path.dirname(tui)
    name = Path.basename(tui)

    case File.ls(dir) do
      {:ok, files} ->
        for file <- files,
            String.starts_with?(file, name <> "."),
            String.contains?(file, "in-use-") do
          File.rm(Path.join(dir, file))
        end

        :ok

      {:error, _} ->
        :ok
    end
  end

  # A program that has just exited can hold its files a moment longer on Windows, and so can
  # a virus scanner: a few tries, a second apart.
  defp rename(from, to, s, why, tries \\ 5) do
    case File.rename(from, to) do
      :ok ->
        :ok

      {:error, _reason} when tries > 1 and s.windows? ->
        s.sleep.(1_000)
        rename(from, to, s, why, tries - 1)

      {:error, reason} ->
        {:error, "#{why} (#{:file.format_error(reason)})"}
    end
  end

  # -- --rollback -----------------------------------------------------------------

  defp rollback(s) do
    daemon? = File.dir?(s.lib) and File.dir?(s.lib <> ".previous")
    tui? = File.regular?(s.tui) and File.regular?(s.tui <> ".previous")
    desktop? = desktop_previous?(s)

    if daemon? or tui? or desktop?,
      do: roll_back(daemon?, tui?, desktop?, s),
      else:
        {:error,
         "nothing to roll back to: there is no #{s.tui}.previous, no #{s.lib}.previous and no desktop app kept as .previous"}
  end

  defp roll_back(daemon?, tui?, desktop?, s) do
    if daemon?, do: s.out.(daemon_rollback_line(s))

    if tui?,
      do: s.out.("  troupe         #{Path.basename(s.tui)} <-> #{Path.basename(s.tui)}.previous")

    if desktop?,
      do:
        s.out.(
          "  the desktop app  #{Path.basename(s.desktop.path)} <-> #{Path.basename(s.desktop.path)}.previous"
        )

    with :ok <- quiet_for(daemon?, s),
         :ok <- exchange_daemon(daemon?, s),
         :ok <- rollback_tui(tui?, daemon?, s),
         :ok <- rollback_desktop(desktop?, s) do
      s.out.("Rolled back. troupe update --rollback again puts back what was there.")
      :ok
    end
  end

  # The AppImage or the app bundle kept beside the one installed; the Windows setup and
  # the extension keep none, which `--check` and an update say.
  defp desktop_previous?(%{desktop: %{kind: :appimage, path: path}}),
    do: File.regular?(path) and File.regular?(path <> ".previous")

  defp desktop_previous?(%{desktop: %{kind: :mac_app, path: app}}),
    do: File.dir?(app) and File.dir?(app <> ".previous")

  defp desktop_previous?(_s), do: false

  defp rollback_desktop(false, _s), do: :ok

  # The two files trade places, and so do the versions kept beside them; the menu entry
  # says the one now in place.
  defp rollback_desktop(true, %{desktop: %{kind: :appimage, path: path}} = s) do
    with :ok <- exchange(path, path <> ".previous", s, false) do
      now = File.read(path <> ".previous.version")
      before = File.read(path <> ".version")
      _ = write_version(path <> ".version", now)
      _ = write_version(path <> ".previous.version", before)

      _ =
        stamp_entry(
          s.desktop[:entry],
          String.trim(elem(write_version(path <> ".version", now), 1))
        )

      :ok
    end
  end

  defp rollback_desktop(true, %{desktop: %{kind: :mac_app, path: app}} = s),
    do: exchange(app, app <> ".previous", s, true)

  defp write_version(file, {:ok, version}) do
    _ = File.write(file, version)
    {:ok, version}
  end

  defp write_version(file, _none) do
    _ = File.write(file, "unknown version\n")
    {:ok, "unknown version\n"}
  end

  defp daemon_rollback_line(s) do
    now = daemon_version(s.lib, s.windows?) || "an unknown version"
    before = daemon_version(s.lib <> ".previous", s.windows?) || "an unknown version"
    "  troupe-daemon  #{now} -> #{before}"
  end

  defp quiet_for(false, _s), do: :ok
  defp quiet_for(true, s), do: s.daemon.(s)

  defp exchange_daemon(false, _s), do: :ok
  defp exchange_daemon(true, s), do: exchange(s.lib, s.lib <> ".previous", s, true)

  defp rollback_tui(false, _daemon?, _s), do: :ok

  defp rollback_tui(true, daemon?, s) do
    s.tui
    |> exchange(s.tui <> ".previous", s, false)
    |> undoing(fn -> exchange_daemon(daemon?, s) end)
  end

  # `a` and `b` trade places. A directory, or any file on Windows, goes through a third
  # name; a file on Unix is linked to that name first, so `a` is never missing.
  defp exchange(a, b, s, dir?) do
    swap = a <> ".swap"
    _ = File.rm_rf(swap)
    moved? = dir? or s.windows?

    with :ok <- aside(a, swap, moved?, s),
         :ok <-
           b
           |> rename(a, s, "#{b} could not be moved into #{a}")
           |> undoing(fn -> back(swap, a, moved?) end) do
      rename(swap, b, s, "#{a} was rolled back, but the one it replaced is left as #{swap}")
    end
  end

  defp aside(a, swap, true, s),
    do: rename(a, swap, s, "#{a} could not be moved aside: something still runs from it")

  defp aside(a, swap, false, _s), do: link_or_copy(a, swap)

  defp back(swap, a, true), do: File.rename(swap, a)
  defp back(swap, _a, false), do: File.rm(swap)

  defp link_or_copy(from, to) do
    with {:error, _} <- File.ln(from, to),
         {:error, reason} <- File.cp(from, to) do
      {:error, "#{from} could not be kept as #{to}: #{:file.format_error(reason)}"}
    end
  end

  # -- the daemon -----------------------------------------------------------------

  @doc """
  Have the daemon that serves this machine stop between turns, and wait until it has.

  It is asked with `daemon.stop`. While a turn is at work it says which, and is asked
  again every two seconds, for as long as that takes; the line saying what it waits for
  is printed again only when that changes. A daemon a TUI runs inside itself says so and
  is left running; one too old to have `daemon.stop` is refused, with what to do, since it
  cannot be stopped between turns from here.
  """
  @spec quiet_daemon(map()) :: :ok | {:error, String.t()}
  def quiet_daemon(s) do
    info = %{"name" => "troupe update", "version" => s.installed || "unknown"}

    case Daemon.connect(spawn: false, client_info: info) do
      {:ok, client} ->
        try do
          ask_to_stop(client, s, nil)
        after
          close(client)
        end

      {:error, _not_running} ->
        :ok
    end
  end

  defp ask_to_stop(client, s, said) do
    case Client.call(client, "daemon.stop", %{}) do
      {:ok, %{"stopping" => true}} ->
        s.out.("troupe-daemon stops now, between turns")
        gone(s, 240)

      {:ok, %{"reason" => "embedded"}} ->
        s.out.(
          "the daemon here runs inside a troupe, which stops it when it exits; it is left running"
        )

        :ok

      {:ok, %{"reason" => "at_work"} = answer} ->
        line =
          "waiting for troupe-daemon to finish the turn at work in #{workspaces(answer["at_work"])}; " <>
            "Ctrl-C leaves everything as it was"

        if line != said, do: s.out.(line)
        s.sleep.(2_000)
        ask_to_stop(client, s, line)

      {:error, %{message: "method_not_found"}} ->
        {:error,
         "the troupe-daemon running here is from before it could be asked to stop between turns. " <>
           "It stops on its own ten minutes after nothing uses it; run troupe update then. Nothing changed"}

      {:error, error} ->
        {:error,
         "troupe-daemon did not say whether it can stop (#{inspect(error)}); nothing changed"}
    end
  end

  defp workspaces(rows) when is_list(rows) and rows != [] do
    rows |> Enum.map(&(&1["workspace"] || &1["id"])) |> Enum.uniq() |> Enum.join(", ")
  end

  defp workspaces(_rows), do: "a session"

  # Gone once nothing answers where it listened: asked every quarter second, for a minute.
  defp gone(_s, 0),
    do:
      {:error,
       "troupe-daemon said it would stop, and still answers a minute later; nothing changed"}

  defp gone(s, tries) do
    if Daemon.running?() do
      s.sleep.(250)
      gone(s, tries - 1)
    else
      :ok
    end
  end

  defp close(client) do
    Client.close(client)
  catch
    :exit, _ -> :ok
  end

  # -- fetching -----------------------------------------------------------------

  @doc """
  Fetch `url` into `dest`, or as a binary when `dest` is `:binary`. https, http and
  `file://` URLs; a missing file is `{:error, :not_found}`.
  """
  @spec fetch(String.t(), Path.t() | :binary) ::
          :ok | {:ok, binary()} | {:error, :not_found | String.t()}
  def fetch("file://" <> _ = url, dest) do
    path = file_path(url)

    result = if dest == :binary, do: File.read(path), else: File.cp(path, dest)

    case result do
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, "#{path} could not be read: #{:file.format_error(reason)}"}
      ok -> ok
    end
  end

  def fetch("http" <> _ = url, dest) do
    result = url |> Req.get(req_options(dest)) |> answered(url, dest)
    if dest != :binary and result != :ok, do: File.rm(dest)
    result
  end

  def fetch(url, _dest), do: {:error, "#{url}: troupe update reads https, http and file:// URLs"}

  defp req_options(:binary),
    do: [raw: true, retry: :transient, max_retries: 2, receive_timeout: 60_000]

  defp req_options(dest), do: [into: File.stream!(dest)] ++ req_options(:binary)

  defp answered({:ok, %Req.Response{status: 200, body: body}}, _url, :binary), do: {:ok, body}
  defp answered({:ok, %Req.Response{status: 200}}, _url, _dest), do: :ok
  defp answered({:ok, %Req.Response{status: 404}}, _url, _dest), do: {:error, :not_found}

  defp answered({:ok, %Req.Response{status: status}}, url, _dest),
    do: {:error, "#{url} answered #{status}"}

  defp answered({:error, exception}, url, _dest),
    do: {:error, "could not reach #{url}: #{Exception.message(exception)}"}

  # `file:///C:/x` on Windows is `C:/x`, and `file:///home/x` elsewhere is `/home/x`.
  defp file_path(url) do
    path = URI.decode(URI.parse(url).path || "")
    if Regex.match?(~r{\A/[A-Za-z]:}, path), do: String.slice(path, 1..-1//1), else: path
  end
end
