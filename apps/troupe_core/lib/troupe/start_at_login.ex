defmodule Troupe.StartAtLogin do
  @moduledoc """
  Whether `troupe-daemon` starts when this person logs in: the one place that writes the
  login entry, removes it and says whether it is there (Decision 762). `troupe-daemon
  login on|off|status` and the first run's `daemon` step (`Troupe.Setup`) both come here.

  The entry is the platform's own per-user one, and none needs an administrator:

    * Windows: `troupe-daemon.cmd` in the user's Startup folder
      (`%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup`), which starts the
      daemon in a console minimised to the taskbar, where it can be seen and closed.
    * macOS: a launchd agent, `~/Library/LaunchAgents/com.objective-mj.troupe.daemon.plist`,
      run at load.
    * Linux with systemd: a `systemd --user` unit,
      `$XDG_CONFIG_HOME/systemd/user/troupe-daemon.service`, wanted by `default.target`
      through the link `systemctl --user enable` would make.
    * Linux without systemd: an XDG autostart entry,
      `$XDG_CONFIG_HOME/autostart/troupe-daemon.desktop`, which a desktop session starts.

  Each runs `troupe-daemon run`, as a client does when it starts the daemon on demand, with
  `TROUPE_DAEMON_IDLE_MINUTES=0`: a daemon started at login stays up until the person logs
  out or stops it, rather than exiting ten minutes later with nobody attached. One a client
  starts still exits when idle.

  Only files are written. Nothing is loaded into launchd or systemd here, so turning it on
  takes effect at the next login, and turning it off stops nothing that is running.

  Options, over the `:troupe_core, :start_at_login` application environment (which is how
  a test suite keeps every call away from the real login items): `:kind`, one of `kinds/0`;
  `:env`, a map read before the environment for `APPDATA`, `HOME`, `XDG_CONFIG_HOME` and
  `TROUPE_DAEMON_COMMAND` (a key with `nil` is a variable not set);
  `:command`, the `troupe-daemon` to start; `:find` and `:release_root`, where that is
  looked for when not given.
  """

  @type kind :: :startup_folder | :launch_agent | :systemd | :autostart

  @kinds [:startup_folder, :launch_agent, :systemd, :autostart]
  @name "troupe-daemon"
  @label "com.objective-mj.troupe.daemon"
  @idle "TROUPE_DAEMON_IDLE_MINUTES"

  @doc "Every kind of entry, one per platform and two on Linux."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc """
  The kind of entry this platform takes: `:os` and `:systemd?` stand in for the machine.
  Linux has systemd when `/run/systemd/system` exists, which is how systemd itself says it
  booted the machine; elsewhere an autostart entry is what a desktop session reads.
  """
  @spec kind(keyword()) :: kind()
  def kind(opts \\ []) do
    opts = options(opts)

    case opts[:kind] || Keyword.get(opts, :os, :os.type()) do
      kind when kind in @kinds ->
        kind

      {:win32, _} ->
        :startup_folder

      {:unix, :darwin} ->
        :launch_agent

      {:unix, _} ->
        if Keyword.get_lazy(opts, :systemd?, &systemd?/0), do: :systemd, else: :autostart
    end
  end

  defp systemd?, do: File.dir?("/run/systemd/system")

  @doc "Where an entry of `kind` is written."
  @spec path(kind(), keyword()) :: Path.t()
  def path(kind, opts \\ []), do: entry_path(kind, options(opts))

  defp entry_path(:startup_folder, opts) do
    roaming = env(opts, "APPDATA") || Path.join([home(opts), "AppData", "Roaming"])

    Path.join([
      roaming,
      "Microsoft",
      "Windows",
      "Start Menu",
      "Programs",
      "Startup",
      @name <> ".cmd"
    ])
  end

  defp entry_path(:launch_agent, opts),
    do: Path.join([home(opts), "Library", "LaunchAgents", @label <> ".plist"])

  defp entry_path(:systemd, opts),
    do: Path.join([config_home(opts), "systemd", "user", @name <> ".service"])

  defp entry_path(:autostart, opts),
    do: Path.join([config_home(opts), "autostart", @name <> ".desktop"])

  # What `systemctl --user enable` makes for a unit `WantedBy=default.target`.
  defp wants(opts),
    do:
      Path.join([
        config_home(opts),
        "systemd",
        "user",
        "default.target.wants",
        @name <> ".service"
      ])

  @doc """
  Whether the daemon starts at login, by which kind of entry, where that is, and the
  `troupe-daemon` turning it on would start (`nil` when there is none to find).
  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    opts = options(opts)
    kind = kind(opts)

    %{
      "at_login" => on?(kind, opts),
      "kind" => Atom.to_string(kind),
      "path" => Troupe.Paths.display(path(kind, opts)),
      "command" =>
        case command(opts) do
          {:ok, command} -> Troupe.Paths.display(command)
          {:error, _reason} -> nil
        end
    }
  end

  defp on?(:systemd, opts), do: File.regular?(path(:systemd, opts)) and link?(wants(opts))
  defp on?(kind, opts), do: File.regular?(path(kind, opts))

  defp link?(path), do: match?({:ok, _}, File.lstat(path))

  @doc """
  Write the entry, or write it again: the second time picks up a `troupe-daemon` that has
  moved. Fails, writing nothing, when there is no `troupe-daemon` to start.
  """
  @spec enable(keyword()) :: {:ok, map()} | {:error, String.t()}
  def enable(opts \\ []) do
    opts = options(opts)
    kind = kind(opts)
    file = path(kind, opts)

    with {:ok, command} <- command(opts),
         :ok <- write(file, entry(kind, command)),
         :ok <- enable_unit(kind, file, opts) do
      {:ok, status(opts)}
    end
  end

  defp enable_unit(:systemd, unit, opts) do
    link = wants(opts)

    with :ok <- mkdir(Path.dirname(link)),
         :ok <- remove(link),
         :ok <- File.ln_s(unit, link) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, could_not("link", link, reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enable_unit(_kind, _file, _opts), do: :ok

  @doc """
  Remove the entry, and on Linux either kind of it, so one written before systemd was
  there goes too. Nothing there is not a failure.
  """
  @spec disable(keyword()) :: {:ok, map()} | {:error, String.t()}
  def disable(opts \\ []) do
    opts = options(opts)

    files =
      case kind(opts) do
        linux when linux in [:systemd, :autostart] ->
          [wants(opts), path(:systemd, opts), path(:autostart, opts)]

        kind ->
          [path(kind, opts)]
      end

    removed =
      Enum.reduce_while(files, :ok, fn file, :ok ->
        case remove(file) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- removed, do: {:ok, status(opts)}
  end

  @doc """
  The `troupe-daemon` an entry starts: `:command`, then `TROUPE_DAEMON_COMMAND`, then
  `troupe-daemon` on the `PATH` (alone, not the current directory: Decision 846) — the shim
  the installers put there, which keeps its path across an upgrade — and last the wrapper
  of the release this runs in.
  """
  @spec command(keyword()) :: {:ok, Path.t()} | {:error, String.t()}
  def command(opts \\ []) do
    opts = options(opts)
    find = Keyword.get(opts, :find, &Troupe.Executable.find/1)
    root = Keyword.get_lazy(opts, :release_root, fn -> to_string(:code.root_dir()) end)
    given = env(opts, "TROUPE_DAEMON_COMMAND")

    cond do
      is_binary(opts[:command]) ->
        {:ok, opts[:command]}

      given && Path.type(given) == :absolute ->
        {:ok, given}

      found = find.(@name) ->
        {:ok, found}

      wrapper = release_wrapper(root) ->
        {:ok, wrapper}

      true ->
        {:error,
         "#{@name} is not on the PATH, so there is nothing to start at login; install it first"}
    end
  end

  defp release_wrapper(root) do
    name = if match?({:win32, _}, :os.type()), do: @name <> ".cmd", else: @name
    wrapper = Path.join([root, "bin", name])
    if File.regular?(wrapper), do: wrapper
  end

  # -- the entries ------------------------------------------------------------------

  @doc "What an entry of `kind` holds, starting `command`."
  @spec entry(kind(), Path.t()) :: String.t()
  def entry(:startup_folder, command) do
    # A batch file is read in the console's code page: a path beyond ASCII (a user name
    # with an ø in it) is read as UTF-8 only once the page is switched. `%` is a
    # variable there, and `start` runs a batch file under `cmd /k`, which would leave
    # the window open after the daemon exits, so it is `cmd /c` explicitly.
    path = command |> String.replace("/", "\\") |> String.replace("%", "%%")
    utf8 = if path =~ ~r/[^\x00-\x7F]/u, do: ["chcp 65001 >nul"], else: []

    (["@echo off", "rem Starts #{@name} when you log in. `#{@name} login off` removes this file."] ++
       utf8 ++
       [~s(set "#{@idle}=0"), ~s(start "#{@name}" /min cmd /c ""#{path}" run"), ""])
    |> Enum.join("\r\n")
  end

  def entry(:launch_agent, command) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{xml(command)}</string>
        <string>run</string>
      </array>
      <key>EnvironmentVariables</key>
      <dict>
        <key>#{@idle}</key>
        <string>0</string>
      </dict>
      <key>RunAtLoad</key>
      <true/>
    </dict>
    </plist>
    """
  end

  def entry(:systemd, command) do
    """
    # Starts #{@name} when you log in. `#{@name} login off` removes this file.
    [Unit]
    Description=Troupe daemon, started at login

    [Service]
    Type=simple
    ExecStart=#{systemd_word(command)} run
    Environment=#{@idle}=0

    [Install]
    WantedBy=default.target
    """
  end

  def entry(:autostart, command) do
    """
    [Desktop Entry]
    Type=Application
    Name=Troupe daemon
    Comment=Starts #{@name} when you log in; #{@name} login off removes this file
    Exec=env #{@idle}=0 #{desktop_word(command)} run
    Terminal=false
    NoDisplay=true
    """
  end

  defp xml(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # One word of `ExecStart=`: quoted, with systemd's specifiers and variables escaped.
  defp systemd_word(word) do
    escaped =
      word
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("%", "%%")
      |> String.replace("$", "$$")

    ~s("#{escaped}")
  end

  # One word of `Exec=`: quoted as the desktop entry spec quotes an argument, then the
  # backslashes escaped again because the value is a string, and `%` kept from being a
  # field code.
  defp desktop_word(word) do
    quoted = String.replace(word, ~r/["`$\\]/, "\\\\\\0")
    ~s("#{quoted}") |> String.replace("\\", "\\\\") |> String.replace("%", "%%")
  end

  # -- files ------------------------------------------------------------------------

  defp write(file, contents) do
    with :ok <- mkdir(Path.dirname(file)),
         :ok <- File.write(file, contents) do
      :ok
    else
      {:error, reason} when is_atom(reason) -> {:error, could_not("write", file, reason)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, could_not("create", dir, reason)}
    end
  end

  defp remove(file) do
    case File.rm(file) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, could_not("remove", file, reason)}
    end
  end

  defp could_not(verb, path, reason),
    do: "could not #{verb} #{Troupe.Paths.display(path)}: #{:file.format_error(reason)}"

  # -- where ------------------------------------------------------------------------

  defp options(opts),
    do: Keyword.merge(Application.get_env(:troupe_core, :start_at_login, []), opts)

  defp env(opts, var) do
    case Map.fetch(Keyword.get(opts, :env, %{}), var) do
      {:ok, value} -> present(value)
      :error -> present(System.get_env(var))
    end
  end

  defp home(opts), do: env(opts, "HOME") || System.user_home!()
  defp config_home(opts), do: env(opts, "XDG_CONFIG_HOME") || Path.join(home(opts), ".config")

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
