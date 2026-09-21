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

      assert Enum.any?(said(), &String.contains?(&1, "discovery document"))
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
