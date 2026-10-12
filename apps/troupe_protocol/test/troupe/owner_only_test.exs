defmodule Troupe.OwnerOnlyTest do
  @moduledoc """
  A file only its owner can read, on every platform.

  `daemon.json` (the daemon's port and token) and `mcp-oauth.json` (a person's sign-ins to
  their own MCP servers) were made `0600` with `File.chmod/2`, which does nothing on
  Windows, so there they kept whatever their folder handed down. The suite runs on Linux,
  so Windows is exercised here through the program it runs and what that program prints,
  and for real by the first test wherever the suite runs on Windows.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Troupe.OwnerOnly

  @windows {:win32, :nt}

  setup do
    dir = Path.join(System.tmp_dir!(), "troupe-owner-only-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a file made the owner's alone is, on the platform the suite runs on", %{dir: dir} do
    path = Path.join(dir, "daemon.json")
    File.write!(path, "{}")

    unless match?({:win32, _}, :os.type()) do
      File.chmod!(path, 0o644)
      refute OwnerOnly.restricted?(path)
    end

    assert OwnerOnly.restrict(path) == :ok
    assert OwnerOnly.restricted?(path)
    assert OwnerOnly.restricted?(Path.join(dir, "not-there.json"))
  end

  describe "on Windows" do
    # The user the program is told to grant, whoever runs the suite.
    setup do
      previous = System.get_env("USERNAME")
      System.put_env("USERNAME", "ada")

      on_exit(fn ->
        if previous, do: System.put_env("USERNAME", previous), else: System.delete_env("USERNAME")
      end)
    end

    test "the inherited access is removed and the user alone is granted the file" do
      run = fn program, args ->
        send(self(), {:ran, program, args})
        {:ok, "processed file\r\nSuccessfully processed 1 files; Failed processing 0 files\r\n", 0}
      end

      assert OwnerOnly.restrict("C:/Users/ada/AppData/Local/troupe/daemon.json", os: @windows, run: run) == :ok

      assert_received {:ran, "icacls",
                       ["C:\\Users\\ada\\AppData\\Local\\troupe\\daemon.json", "/inheritance:r", "/grant:r", "ada:F"]}
    end

    test "a file that cannot be restricted is still written, and a warning says which" do
      for answer <- [{:error, {:not_on_path, "icacls"}}, {:ok, "Access is denied.", 5}] do
        log =
          capture_log(fn ->
            assert OwnerOnly.restrict("C:/x/daemon.json", os: @windows, run: fn _, _ -> answer end) == :ok
          end)

        assert log =~ "C:/x/daemon.json"
        assert log =~ "could not be made readable by its owner alone"
      end
    end

    test "only an access list naming the user and nobody else counts", %{dir: dir} do
      path = Path.join(dir, "daemon.json")
      File.write!(path, "{}")
      native = String.replace(path, "/", "\\")

      alone = "#{native} DESKTOP-1\\ada:(F)\r\n\r\nSuccessfully processed 1 files; Failed processing 0 files\r\n"

      inherited =
        "#{native} NT AUTHORITY\\SYSTEM:(I)(F)\r\n" <>
          "    BUILTIN\\Administrators:(I)(F)\r\n    DESKTOP-1\\ada:(I)(F)\r\n\r\n" <>
          "Successfully processed 1 files; Failed processing 0 files\r\n"

      assert OwnerOnly.restricted?(path, os: @windows, run: fn _, _ -> {:ok, alone, 0} end)
      refute OwnerOnly.restricted?(path, os: @windows, run: fn _, _ -> {:ok, inherited, 0} end)
      refute OwnerOnly.restricted?(path, os: @windows, run: fn _, _ -> {:error, :timeout} end)
    end
  end
end
