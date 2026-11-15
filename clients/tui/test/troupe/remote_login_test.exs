defmodule Troupe.RemoteLoginTest do
  @moduledoc """
  Done item 1: `troupe login` completes the device flow against the mock
  issuer, the credential file is user-only, and `troupe whoami` prints identity
  and teams.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers

  alias Troupe.FakeRemote
  alias Troupe.Remote.{Credentials, Discovery, Tokens}

  describe "troupe login" do
    test "runs the device flow, stores a user-only credential file, and whoami prints the teams" do
      {remote, url} =
        start_remote!(
          teams: [%{"id" => "core", "name" => "Core"}, %{"id" => "ops", "name" => "Ops"}]
        )

      lines = login!(remote, url)

      # the code and the URL are on screen before the poll blocks
      assert Enum.any?(lines, &String.contains?(&1, FakeRemote.user_code(remote)))
      assert Enum.any?(lines, &String.contains?(&1, "/device"))
      assert Enum.any?(lines, &String.contains?(&1, "signed in"))
      refute Enum.any?(lines, &String.contains?(&1, "could not restrict"))

      # the wait says what it waits on after a line from the shared set, the facts last
      code = FakeRemote.user_code(remote)

      assert "#{Troupe.UI.Lines.first(:signing_in, code)} — waiting for you to finish in the browser…" in lines

      # the refresh token is on disk, and the file is the user's alone
      assert {:ok, entry} = Credentials.fetch(Discovery.base(url))
      assert entry.refresh_token == "refresh-token"
      assert Credentials.restricted?(Credentials.path())
      assert File.exists?(Credentials.path())

      # whoami names the principal and the teams
      me = self()
      assert 0 == Troupe.CLI.Remote.whoami(nil, say: fn line -> send(me, {:said, line}) end)
      printed = Enum.join(said(), "\n")

      assert printed =~ "Alice"
      assert printed =~ "alice"
      assert printed =~ "Core"
      assert printed =~ "Ops"
    end

    test "a plane with no /auth/exchange is handed the issuer's token" do
      {remote, url} = start_remote!(exchange: false)
      login!(remote, url)

      refute Enum.any?(Troupe.FakeRemote.calls(remote), &match?({"auth.exchange", _}, &1))

      {:ok, origin} = Troupe.Client.connect_plane(url)
      assert {:ok, %{sub: "alice"}} = Troupe.Client.whoami(origin)
    end

    test "the credential file is 0600 on unix" do
      {remote, url} = start_remote!()
      login!(remote, url)

      case :os.type() do
        {:win32, _} ->
          assert Credentials.restricted?(Credentials.path())

        _ ->
          assert {:ok, %File.Stat{mode: mode}} = File.stat(Credentials.path())
          assert Bitwise.band(mode, 0o777) == 0o600
      end
    end

    # The desktop app reads and rotates the same file, so a refresh
    # spends the token the file holds now, not the one this process read at login.
    test "a refresh spends the token another program rotated the file to, under the lock" do
      {remote, url} = start_remote!()
      login!(remote, url)
      plane = Discovery.base(url)
      {:ok, entry} = Credentials.fetch(plane)
      {:ok, _} = Credentials.put(plane, %{entry | refresh_token: "rotated-by-the-desktop-app"})

      assert {:ok, _token} = Tokens.refresh(plane)
      assert ["rotated-by-the-desktop-app" | _] = FakeRemote.refresh_grants(remote)
      refute File.exists?(Credentials.lock_path())
    end

    test "a refresh after another program signed the machine out is a sign-out here too" do
      {remote, url} = start_remote!()
      login!(remote, url)
      plane = Discovery.base(url)
      {:ok, _} = Credentials.delete(plane)

      assert {:error, :logged_out} = Tokens.refresh(plane)
      assert FakeRemote.refresh_grants(remote) == []
    end

    test "the lock is held once at a time, and one a dead process left is broken" do
      lock = Credentials.lock_path()
      File.mkdir_p!(Path.dirname(lock))
      test = self()

      holder =
        spawn_link(fn ->
          Credentials.with_lock(fn ->
            send(test, :held)
            Process.sleep(300)
          end)
        end)

      assert_receive :held
      started = System.monotonic_time(:millisecond)
      assert :done = Credentials.with_lock(fn -> :done end)
      assert System.monotonic_time(:millisecond) - started >= 250
      refute Process.alive?(holder) and File.exists?(lock)

      # Left by a process that died holding it, two minutes ago.
      File.write!(lock, "")
      File.touch!(lock, System.os_time(:second) - 120)
      started = System.monotonic_time(:millisecond)
      assert :done = Credentials.with_lock(fn -> :done end)
      assert System.monotonic_time(:millisecond) - started < 2_000
      refute File.exists?(lock)
    end

    test "logout forgets the plane" do
      {remote, url} = start_remote!()
      login!(remote, url)
      me = self()

      assert 0 == Troupe.CLI.Remote.logout(nil, say: fn line -> send(me, {:said, line}) end)
      assert Enum.any?(said(), &String.contains?(&1, "signed out"))
      assert :error = Credentials.fetch(Discovery.base(url))
      assert {:error, :logged_out} = Tokens.access_token(Discovery.base(url))
    end

    test "a plane that does not answer fails with a message rather than a crash" do
      me = self()

      assert 1 ==
               Troupe.CLI.Remote.login("http://127.0.0.1:1/",
                 sleep: fn _ -> :ok end,
                 say: fn line -> send(me, {:said, line}) end
               )

      # Said in words, with the address, not as the HTTP client's term (#930).
      assert "could not reach http://127.0.0.1:1 (econnrefused); check the address and your network" in said()
    end

    test "an address that is not a plane's says so in words" do
      failed = &Troupe.CLI.Remote.discovery_failed("https://id.example", &1)

      assert failed.({:http, 404, "<html>not here</html>"}) ==
               "https://id.example is not a Troupe plane: https://id.example/.well-known/troupe " <>
                 "was not found (HTTP 404); check the address, which is the plane's own and not " <>
                 "its identity provider's"

      assert failed.({:http, 502, ""}) ==
               "could not read the plane's discovery document: " <>
                 "https://id.example/.well-known/troupe answered HTTP 502"

      assert failed.({:malformed_json, "<html>"}) ==
               "https://id.example is not a Troupe plane: https://id.example/.well-known/troupe is not JSON"

      assert failed.({:discovery_missing, "plane_ws"}) ==
               "the plane's discovery document at https://id.example/.well-known/troupe has no plane_ws"

      refute failed.(:nxdomain) =~ ":nxdomain"
    end
  end

  describe "discovery" do
    test "reads the contract's shape and the live deployment's shape alike" do
      contract = %{
        "issuer" => "https://issuer.example/dex",
        "client_id" => "troupe",
        "plane_ws" => "wss://plane.example/rpc",
        "protocol_versions" => [1]
      }

      assert {:ok, disc} = Discovery.normalise("https://plane.example", contract)
      assert disc.ws_url == "wss://plane.example/rpc"
      assert disc.protocol_versions == [1]
      assert disc.scopes == ~w(openid profile groups offline_access)

      # what the deployment this was built against actually answers
      live = %{
        "issuer" => "http://dex.localtest.me:30080/dex",
        "client_id" => "troupe",
        "device_authorization_endpoint" => "http://dex.localtest.me:30080/dex/device/code",
        "token_endpoint" => "http://dex.localtest.me:30080/dex/token",
        "scopes" => ["openid", "profile", "email", "offline_access"],
        "plane" => %{
          "name" => "troupe",
          "rpc" => "/rpc",
          "protocol_version" => "1",
          "jwks" => "/.well-known/jwks.json"
        }
      }

      assert {:ok, disc} = Discovery.normalise("http://plane.localtest.me:30080", live)
      assert disc.ws_url == "ws://plane.localtest.me:30080/rpc"
      assert disc.protocol_versions == [1]
      assert disc.scopes == ["openid", "profile", "email", "offline_access"]
      assert disc.device_endpoint == "http://dex.localtest.me:30080/dex/device/code"
      assert Discovery.compatible?(disc)
    end

    test "a plane speaking only a future protocol is not compatible" do
      assert {:ok, disc} =
               Discovery.normalise("https://plane.example", %{
                 "issuer" => "https://i.example",
                 "client_id" => "troupe",
                 "plane_ws" => "wss://plane.example/rpc",
                 "protocol_versions" => [2, 3]
               })

      refute Discovery.compatible?(disc)
    end
  end
end
