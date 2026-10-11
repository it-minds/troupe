defmodule Troupe.Update do
  @moduledoc """
  `troupe update`: a release, checked, then swapped in for the troupe and the
  troupe-daemon the installers put on this machine (#66, Decision 865).

      troupe update --check            what is installed, the latest release, and what an update would do
      troupe update [--version X]      install the latest release, or X
      troupe update --rollback         put the previous troupe and troupe-daemon back

  **Where from.** `TROUPE_RELEASE_URL`, when it is set, is one release's assets, as the
  installers read it: a mirror, or a `file://` directory. Otherwise GitHub's: the latest
  release is the one `/releases/latest` redirects to, and `--version X` is the tag `vX`.

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
  """

  alias Troupe.Protocol.{Client, Daemon}
  alias Troupe.Release.{Keys, Manifest, Minisign}

  @repo "it-minds/troupe"
  # A manifest and its signature are a few kilobytes; anything much bigger is not one.
  @small 1_048_576

  @type action :: :check | :update | :rollback

  @doc """
  Run one action and return the exit status.

  `opts`: `:version` (the release asked for), `:installed` (this troupe's version), and,
  standing in for the machine in tests, `:release_url`, `:repo`, `:keys`, `:target`,
  `:tui`, `:lib`, `:windows?`, `:out` (a line printed), `:fetch`, `:daemon` (what quiets
  the daemon) and `:sleep`.
  """
  @spec run(action(), keyword()) :: non_neg_integer()
  def run(action, opts \\ []) do
    s = settings(opts)

    result =
      case action do
        :check -> check(s)
        :update -> update(s)
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
      installed: opts[:installed],
      release_url: Keyword.get_lazy(opts, :release_url, fn -> env("TROUPE_RELEASE_URL") end),
      repo: Keyword.get_lazy(opts, :repo, fn -> env("TROUPE_REPO") || @repo end),
      keys: Keyword.get_lazy(opts, :keys, &Keys.trusted/0),
      target: Keyword.get_lazy(opts, :target, &Manifest.target/0),
      tui: Keyword.get_lazy(opts, :tui, fn -> tui_path(windows?) end),
      lib: Keyword.get_lazy(opts, :lib, fn -> lib_dir(windows?) end),
      windows?: windows?,
      out: Keyword.get(opts, :out, &IO.puts/1),
      fetch: Keyword.get(opts, :fetch, &fetch/2),
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

  defp installed(s) do
    %{
      tui: if(File.regular?(s.tui), do: s.installed || "unknown version"),
      daemon: daemon_version(s.lib, s.windows?)
    }
  end

  # -- --check ------------------------------------------------------------------

  defp check(s) do
    inst = installed(s)
    s.out.("  troupe         #{inst.tui || "not installed"}  #{s.tui}")
    s.out.("  troupe-daemon  #{inst.daemon || "not installed"}  #{s.lib}")

    with {:ok, rel} <- release(s) do
      s.out.("  release        #{rel.version}  #{rel.base}")
      s.out.("                 manifest signed by release key #{Enum.join(rel.key_ids, " and ")}")

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

  # -- the release ----------------------------------------------------------------

  @doc false
  @spec release(map()) :: {:ok, map()} | {:error, String.t()}
  def release(s) do
    with {:ok, base, tag} <- source(s),
         {:ok, bytes} <- get_small(s, base, "manifest.json"),
         {:ok, signature} <- get_small(s, base, "manifest.json.minisig"),
         {:ok, signed} <- signed(bytes, signature, s.keys, base),
         {:ok, manifest} <- decoded(bytes, base),
         :ok <- asked_for(manifest, s.version, tag, base) do
      {:ok, %{version: manifest.version, base: base, manifest: manifest, key_ids: signed.key_ids}}
    end
  end

  defp source(%{release_url: url}) when is_binary(url),
    do: {:ok, String.trim_trailing(url, "/"), nil}

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

  # -- the plan -----------------------------------------------------------------

  defp plan(rel, s) do
    inst = installed(s)

    candidates =
      Enum.reject(
        [{"troupe-daemon", "daemon", inst.daemon}, {"troupe", "tui", inst.tui}],
        &is_nil(elem(&1, 2))
      )

    cond do
      candidates == [] ->
        {:error,
         "no troupe at #{s.tui} and no troupe-daemon in #{s.lib}: troupe update replaces what the installers put there"}

      s.target == nil ->
        {:error, "this machine is not one a release is built for"}

      true ->
        candidates
        |> Enum.filter(fn {_name, _component, from} ->
          wanted?(from, rel.version, s.version != nil)
        end)
        |> Enum.reduce_while({:ok, []}, &add_step(&1, &2, rel, s))
        |> case do
          {:ok, steps} -> {:ok, %{steps: steps, version: rel.version}}
          error -> error
        end
    end
  end

  defp add_step({name, component, from}, {:ok, steps}, rel, s) do
    case Manifest.find(rel.manifest, component, s.target) do
      nil ->
        {:halt, {:error, "release #{rel.version} has no #{name} for #{s.target}"}}

      artifact ->
        step = %{name: name, component: component, from: from, artifact: artifact}
        {:cont, {:ok, steps ++ [step]}}
    end
  end

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

      if plan.steps == [] do
        s.out.("Nothing to update: what is installed is #{rel.version} or newer.")
        :ok
      else
        install(plan, rel, s)
      end
    end
  end

  defp install(plan, rel, s) do
    Enum.each(plan.steps, &s.out.("  #{&1.name}  #{&1.from} -> #{rel.version}"))

    with {:ok, staged} <- download(plan.steps, rel, s),
         :ok <- quiet(staged, s),
         :ok <- swap_in(staged, s) do
      Enum.each(staged, fn step -> s.out.(installed_line(step, rel.version, s)) end)
      s.out.("Done. troupe update --rollback puts what was there before back.")
      :ok
    else
      {:error, why} ->
        clean_staging(plan.steps, s)
        {:error, why}
    end
  end

  defp installed_line(%{component: "daemon", from: from}, version, s),
    do:
      "troupe-daemon #{version} is in #{s.lib} (#{from} kept as #{Path.basename(s.lib)}.previous)"

  defp installed_line(%{component: "tui", from: from}, version, s),
    do: "troupe #{version} is #{s.tui} (#{from} kept as #{Path.basename(s.tui)}.previous)"

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

  defp clean_staging(steps, s) do
    for step <- steps do
      _ = File.rm(download_path(step, s))
      if step.component == "daemon", do: File.rm_rf(s.lib <> ".new")
    end

    :ok
  end

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

    if daemon? or tui?,
      do: roll_back(daemon?, tui?, s),
      else:
        {:error,
         "nothing to roll back to: there is no #{s.tui}.previous and no #{s.lib}.previous"}
  end

  defp roll_back(daemon?, tui?, s) do
    if daemon?, do: s.out.(daemon_rollback_line(s))

    if tui?,
      do: s.out.("  troupe         #{Path.basename(s.tui)} <-> #{Path.basename(s.tui)}.previous")

    with :ok <- quiet_for(daemon?, s),
         :ok <- exchange_daemon(daemon?, s),
         :ok <- rollback_tui(tui?, daemon?, s) do
      s.out.("Rolled back. troupe update --rollback again puts back what was there.")
      :ok
    end
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
