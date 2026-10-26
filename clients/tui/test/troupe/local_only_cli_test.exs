defmodule Troupe.LocalOnlyCLITest do
  @moduledoc """
  Local only in the terminal (root #765, the daemon honours Local only): `local_only: true`
  in the person's own config. Read as a command starts; on, every connection to the daemon
  says `client_info.local_only`, the commands that would call a plane themselves are refused
  with a sentence saying why, and `troupe doctor` says it is on and asks no plane. Off, it
  says nothing on the wire. `async: false`: the user file is the suite's, and the setting
  is held in the application environment for the run.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Troupe.CLI
  alias Troupe.CLI.{Doctor, LocalOnly, Runner}
  alias Troupe.Client.Daemon.Link

  setup do
    user = Troupe.Config.user_path()
    before = File.read!(user)

    on_exit(fn ->
      File.write!(user, before)
      Application.delete_env(:troupe, :local_only)
    end)

    %{user: user}
  end

  test "on in the user's config, the daemon is told and a plane command is refused", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\nlocal_only: true\n")

    {:ok, args} = CLI.parse(["login", "https://plane.example.test"])
    assert {:local_only, refusal} = Runner.local_only({:ok, args})
    assert refusal =~ "troupe login calls a plane, and Local only is on"
    assert LocalOnly.on?()
    assert Link.client_info()["local_only"] == true

    for argv <- [["whoami"], ["config", "pull"], ["--remote"], ["--private"]] do
      {:ok, args} = CLI.parse(argv)
      assert {:local_only, _why} = Runner.local_only({:ok, args}), inspect(argv)
    end

    # A session here, the doctor and the memory command go on: the daemon keeps the promise.
    for argv <- [[], ["doctor"], ["memory"]] do
      {:ok, args} = CLI.parse(argv)
      assert {:ok, ^args} = Runner.local_only({:ok, args}), inspect(argv)
    end
  end

  test "the doctor says it is on, and asks no plane", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\nlocal_only: true\n")
    {:ok, args} = CLI.parse(["doctor"])
    {:ok, args} = Runner.local_only({:ok, args})

    out = capture_io(fn -> Doctor.run(args) end)
    assert out =~ ~r/^ok    local only +on \(local_only in your config\): troupe calls no plane/m
  end

  test "off, nothing is said on the wire, and the doctor says how to turn it on", %{user: user} do
    File.write!(user, "version: 1\nprovider: fake\n")
    {:ok, args} = CLI.parse(["doctor"])
    {:ok, ^args} = Runner.local_only({:ok, args})

    refute LocalOnly.on?()
    refute Map.has_key?(Link.client_info(), "local_only")

    out = capture_io(fn -> Doctor.run(args) end)
    assert out =~ ~r/^ok    local only +off; local_only: true in your config turns it on$/m
  end
end
