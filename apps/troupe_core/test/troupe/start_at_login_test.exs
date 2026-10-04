defmodule Troupe.StartAtLoginTest do
  @moduledoc """
  Starting the daemon at login (Decision 762): each platform's entry written into a
  scratch home, what it starts and how, and its removal. Nothing here reaches the login
  items of the person running the suite: `HOME`, `APPDATA` and `XDG_CONFIG_HOME` are given
  as options pointing at a scratch directory, and nothing is loaded into launchd or
  systemd.
  """

  use ExUnit.Case, async: true

  alias Troupe.StartAtLogin

  @command "/opt/troupe dir/bin/troupe-daemon"

  setup do
    home = Path.join(System.tmp_dir!(), "troupe-login-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    env = %{
      "HOME" => home,
      "APPDATA" => Path.join([home, "AppData", "Roaming"]),
      "XDG_CONFIG_HOME" => Path.join(home, ".config"),
      "TROUPE_DAEMON_COMMAND" => nil
    }

    %{home: home, env: env}
  end

  defp opts(ctx, kind, extra \\ []),
    do: Keyword.merge([kind: kind, env: ctx.env, command: @command], extra)

  test "each entry is where its platform looks for one", ctx do
    assert StartAtLogin.path(:startup_folder, env: ctx.env) ==
             Path.join([
               ctx.home,
               "AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Startup/troupe-daemon.cmd"
             ])

    assert StartAtLogin.path(:launch_agent, env: ctx.env) ==
             Path.join(ctx.home, "Library/LaunchAgents/com.objective-mj.troupe.daemon.plist")

    assert StartAtLogin.path(:systemd, env: ctx.env) ==
             Path.join(ctx.home, ".config/systemd/user/troupe-daemon.service")

    assert StartAtLogin.path(:autostart, env: ctx.env) ==
             Path.join(ctx.home, ".config/autostart/troupe-daemon.desktop")
  end

  test "the platform decides the kind, and Linux asks whether systemd runs it" do
    assert StartAtLogin.kind(os: {:win32, :nt}) == :startup_folder
    assert StartAtLogin.kind(os: {:unix, :darwin}) == :launch_agent
    assert StartAtLogin.kind(os: {:unix, :linux}, systemd?: true) == :systemd
    assert StartAtLogin.kind(os: {:unix, :linux}, systemd?: false) == :autostart
    assert StartAtLogin.kind(os: {:unix, :freebsd}, systemd?: false) == :autostart
  end

  describe "on Windows" do
    test "a command file in the Startup folder starts the daemon minimised, to stay up", ctx do
      opts = opts(ctx, :startup_folder)
      file = StartAtLogin.path(:startup_folder, opts)

      assert %{"at_login" => false, "kind" => "startup_folder"} = StartAtLogin.status(opts)

      assert {:ok, %{"at_login" => true} = status} = StartAtLogin.enable(opts)
      assert status["path"] == Troupe.Paths.display(file)
      assert status["command"] == Troupe.Paths.display(@command)

      assert File.read!(file) ==
               Enum.join(
                 [
                   "@echo off",
                   "rem Starts troupe-daemon when you log in. `troupe-daemon login off` removes this file.",
                   ~s(set "TROUPE_DAEMON_IDLE_MINUTES=0"),
                   ~s(start "troupe-daemon" /min cmd /c ""\\opt\\troupe dir\\bin\\troupe-daemon" run"),
                   ""
                 ],
                 "\r\n"
               )

      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts)
      refute File.exists?(file)
      # Off when it is off already is not a failure.
      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts)
    end

    test "a path beyond ASCII is read as UTF-8, and a percent sign as itself" do
      text = StartAtLogin.entry(:startup_folder, "C:/Users/Søren/50%/troupe-daemon.cmd")
      assert text =~ "\r\nchcp 65001 >nul\r\n"
      assert text =~ ~s(cmd /c ""C:\\Users\\Søren\\50%%\\troupe-daemon.cmd" run")
    end
  end

  describe "on macOS" do
    test "a launchd agent run at load, its path escaped for XML", ctx do
      opts = opts(ctx, :launch_agent, command: "/Users/me/A & B/troupe-daemon")
      file = StartAtLogin.path(:launch_agent, opts)

      assert {:ok, %{"at_login" => true, "kind" => "launch_agent"}} = StartAtLogin.enable(opts)

      assert File.read!(file) == """
             <?xml version="1.0" encoding="UTF-8"?>
             <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
             <plist version="1.0">
             <dict>
               <key>Label</key>
               <string>com.objective-mj.troupe.daemon</string>
               <key>ProgramArguments</key>
               <array>
                 <string>/Users/me/A &amp; B/troupe-daemon</string>
                 <string>run</string>
               </array>
               <key>EnvironmentVariables</key>
               <dict>
                 <key>TROUPE_DAEMON_IDLE_MINUTES</key>
                 <string>0</string>
               </dict>
               <key>RunAtLoad</key>
               <true/>
             </dict>
             </plist>
             """

      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts)
      refute File.exists?(file)
    end
  end

  describe "on Linux" do
    test "a systemd user unit, enabled with the link systemctl would make", ctx do
      opts = opts(ctx, :systemd, command: "/home/me/my $HOME/50%/troupe-daemon")
      unit = StartAtLogin.path(:systemd, opts)

      link =
        Path.join(ctx.home, ".config/systemd/user/default.target.wants/troupe-daemon.service")

      assert {:ok, %{"at_login" => true, "kind" => "systemd"}} = StartAtLogin.enable(opts)

      text = File.read!(unit)
      assert text =~ ~s(ExecStart="/home/me/my $$HOME/50%%/troupe-daemon" run\n)
      assert text =~ "Environment=TROUPE_DAEMON_IDLE_MINUTES=0\n"
      assert text =~ "WantedBy=default.target\n"
      assert File.read_link!(link) == unit

      # A second time writes it again rather than failing on the link.
      assert {:ok, %{"at_login" => true}} = StartAtLogin.enable(opts)

      # A unit nothing wants is disabled: off, as systemctl would say.
      File.rm!(link)
      assert %{"at_login" => false} = StartAtLogin.status(opts)

      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts)
      refute File.exists?(unit)
    end

    test "an XDG autostart entry where there is no systemd", ctx do
      opts = opts(ctx, :autostart, command: ~S(/home/me/a "b"/troupe-daemon))
      file = StartAtLogin.path(:autostart, opts)

      assert {:ok, %{"at_login" => true, "kind" => "autostart"}} = StartAtLogin.enable(opts)

      text = File.read!(file)
      assert text =~ "[Desktop Entry]\nType=Application\n"

      assert text =~
               ~S(Exec=env TROUPE_DAEMON_IDLE_MINUTES=0 "/home/me/a \\"b\\"/troupe-daemon" run) <>
                 "\n"

      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts)
      refute File.exists?(file)
    end

    test "turning it off removes either kind, so one from before systemd goes too", ctx do
      assert {:ok, _} = StartAtLogin.enable(opts(ctx, :autostart))
      assert {:ok, _} = StartAtLogin.enable(opts(ctx, :systemd))

      assert {:ok, %{"at_login" => false}} = StartAtLogin.disable(opts(ctx, :systemd))
      refute File.exists?(StartAtLogin.path(:autostart, env: ctx.env))
      refute File.exists?(StartAtLogin.path(:systemd, env: ctx.env))
    end
  end

  describe "the troupe-daemon it starts" do
    test "is found on the PATH, else is the release's own wrapper", ctx do
      # `command: nil` sets aside the suite's own (test_helper.exs).
      opts = [command: nil, env: ctx.env]
      found = fn "troupe-daemon" -> "/usr/local/bin/troupe-daemon" end
      assert StartAtLogin.command([find: found] ++ opts) == {:ok, "/usr/local/bin/troupe-daemon"}

      name = if match?({:win32, _}, :os.type()), do: "troupe-daemon.cmd", else: "troupe-daemon"
      wrapper = Path.join([ctx.home, "bin", name])
      File.mkdir_p!(Path.dirname(wrapper))
      File.write!(wrapper, "")

      none = fn _ -> nil end
      assert StartAtLogin.command([find: none, release_root: ctx.home] ++ opts) == {:ok, wrapper}

      given = Map.put(ctx.env, "TROUPE_DAEMON_COMMAND", "/opt/other/troupe-daemon")

      assert StartAtLogin.command(command: nil, env: given, find: found) ==
               {:ok, "/opt/other/troupe-daemon"}
    end

    test "nowhere means turning it on writes nothing and says why", ctx do
      # `command: nil` sets aside the suite's own (test_helper.exs).
      opts = [
        kind: :systemd,
        env: ctx.env,
        command: nil,
        find: fn _ -> nil end,
        release_root: ctx.home
      ]

      assert {:error, reason} = StartAtLogin.enable(opts)
      assert reason =~ "troupe-daemon is not on the PATH"
      assert %{"at_login" => false, "command" => nil} = StartAtLogin.status(opts)
      refute File.exists?(StartAtLogin.path(:systemd, opts))
    end
  end
end
