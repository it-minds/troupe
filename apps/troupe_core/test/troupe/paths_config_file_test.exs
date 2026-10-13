defmodule Troupe.Paths.ConfigFileTest do
  @moduledoc """
  One directory for a person's own files (issue #658): `credentials.json` and `mcp.json`
  beside `config.yaml`, and on Windows the two an older build kept under
  `~\\.config\\troupe` moved in the first time they are asked for, so a person's sign-in
  and servers keep working. Windows is played with `os: {:win32, :nt}` and a stand-in for
  `icacls`; the directories are scratch ones.

  `async: false`: `APPDATA`, `XDG_CONFIG_HOME`, `TROUPE_CONFIG_HOME` and `USERNAME` are
  process-global.
  """

  use ExUnit.Case, async: false

  alias Troupe.Paths

  @vars ~w(APPDATA XDG_CONFIG_HOME TROUPE_CONFIG_HOME USERNAME)
  @windows {:win32, :nt}

  setup do
    base =
      Path.join(System.tmp_dir!(), "troupe-config-file-#{System.unique_integer([:positive])}")

    previous = Map.new(@vars, &{&1, System.get_env(&1)})

    System.put_env("APPDATA", Path.join(base, "AppData/Roaming"))
    System.put_env("XDG_CONFIG_HOME", Path.join(base, "home/.config"))
    System.delete_env("TROUPE_CONFIG_HOME")
    System.put_env("USERNAME", "me")

    on_exit(fn ->
      Enum.each(previous, fn {var, value} ->
        if value, do: System.put_env(var, value), else: System.delete_env(var)
      end)

      File.rm_rf!(base)
    end)

    test = self()

    icacls = fn program, args ->
      send(test, {:ran, program, args})
      {:ok, "", 0}
    end

    %{
      new: Path.join(base, "AppData/Roaming/troupe"),
      old: Path.join(base, "home/.config/troupe"),
      opts: [os: @windows, run: icacls]
    }
  end

  defp older(ctx, name, contents) do
    File.mkdir_p!(ctx.old)
    File.write!(Path.join(ctx.old, name), contents)
  end

  test "on Windows, a file an older build kept under .config is moved beside config.yaml and kept to its owner",
       ctx do
    older(ctx, "credentials.json", ~s({"planes": {}}))

    assert Paths.config_file("credentials.json", ctx.opts) ==
             Path.join(ctx.new, "credentials.json")

    assert File.read!(Path.join(ctx.new, "credentials.json")) == ~s({"planes": {}})
    refute File.exists?(Path.join(ctx.old, "credentials.json"))
    assert_received {:ran, "icacls", [_file, "/inheritance:r", "/grant:r" | _]}

    # Asked again, it is the one copy, and nothing more is done.
    assert Paths.config_file("credentials.json", ctx.opts) ==
             Path.join(ctx.new, "credentials.json")

    refute_received {:ran, _, _}
  end

  test "the person's servers in the older mcp.json are the ones the daemon reads", ctx do
    older(ctx, "mcp.json", ~s({"mcpServers": {"docs": {"url": "https://mcp.example.test/mcp"}}}))

    path = Paths.config_file("mcp.json", ctx.opts)
    assert path == Path.join(ctx.new, "mcp.json")
    assert %{"mcpServers" => %{"docs" => _}} = path |> File.read!() |> Jason.decode!()
  end

  test "a file in both places: the one beside config.yaml is read, and the other left as it is",
       ctx do
    older(ctx, "mcp.json", "old")
    File.mkdir_p!(ctx.new)
    File.write!(Path.join(ctx.new, "mcp.json"), "new")

    assert Paths.config_file("mcp.json", ctx.opts) == Path.join(ctx.new, "mcp.json")
    assert File.read!(Path.join(ctx.new, "mcp.json")) == "new"
    assert File.read!(Path.join(ctx.old, "mcp.json")) == "old"
  end

  test "TROUPE_CONFIG_HOME names the directory, which the older build honoured too: nothing moves",
       ctx do
    older(ctx, "credentials.json", "older")
    named = Path.join(Path.dirname(ctx.new), "named")
    System.put_env("TROUPE_CONFIG_HOME", named)

    assert Paths.config_file("credentials.json", ctx.opts) == Path.join(named, "credentials.json")
    refute File.exists?(Path.join(named, "credentials.json"))
    assert File.exists?(Path.join(ctx.old, "credentials.json"))
  end

  test "elsewhere the two places were always one, and nothing moves", ctx do
    older(ctx, "credentials.json", "here")

    assert Paths.config_file("credentials.json", os: {:unix, :linux}) ==
             Path.join(ctx.old, "credentials.json")

    assert File.read!(Path.join(ctx.old, "credentials.json")) == "here"
  end

  test "every file of a person's own is in the one directory config.yaml is in" do
    dir = Paths.config_dir()
    assert Path.dirname(Troupe.Config.user_path()) == dir
    assert Path.dirname(Troupe.MCP.Local.user_path()) == dir
    assert Path.dirname(Paths.config_file("credentials.json")) == dir
    assert Troupe.Skills.Local.user_dir() == Path.join(dir, "skills")
    assert Troupe.Commands.Local.user_dir() == Path.join(dir, "commands")
  end
end
