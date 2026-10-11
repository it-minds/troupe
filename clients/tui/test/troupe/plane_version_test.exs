defmodule Troupe.PlaneVersionTest do
  @moduledoc """
  A plane's version policy as this client meets it (#66 slice 1b, Decision 868).

  The handshake over `/rpc` is the plane's `initialize`, which says what the plane makes of
  this version. A plane that does not serve it refuses the connection with one sentence
  saying what to run, and HQ, `troupe whoami` and every call say that sentence rather than
  that the plane is unreachable. `troupe update` asks the plane signed in to what to install,
  with `me.client_versions`, which a refused client can still ask.
  """

  use ExUnit.Case, async: false

  import Troupe.RemoteHelpers
  import Troupe.TestHelpers
  import Troupe.TUIHelpers

  alias Troupe.Client
  alias Troupe.FakeRemote

  @moduletag :remote

  @version to_string(Application.spec(:troupe, :vsn))

  test "a plane that serves this version is met with initialize, which names the person" do
    {remote, url} =
      start_remote!(transport: :http, client_versions: %{"tui" => %{"recommended" => "99.0.1"}})

    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> Client.fleet_status(origin).up? end)

    assert Enum.any?(
             FakeRemote.calls(remote),
             &match?(
               {"initialize", %{"client_info" => %{"name" => "troupe", "version" => @version}}},
               &1
             )
           )

    status = Client.fleet_status(origin)
    assert %{"sub" => "alice", "name" => "Alice"} = status.principal
    assert status.update_required == nil
  end

  # #66 slice 2 (Decision 874): `suggest` is said, quietly, where the plane is met.
  test "a newer recommended version is one quiet line, with what to run, and never an error" do
    {remote, url} =
      start_remote!(transport: :http, client_versions: %{"tui" => %{"recommended" => "99.0.1"}})

    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> Client.fleet_status(origin).up? end)

    line = "This plane recommends troupe 99.0.1, and this is #{@version}: run troupe update."
    assert Client.fleet_status(origin)[:suggest] == line
    assert Client.fleet_status(origin).update_required == nil

    # troupe whoami says who, then the line, and succeeds.
    me = self()
    assert Troupe.CLI.Remote.whoami(url, say: &send(me, {:said, &1})) == 0
    assert_received {:said, ^line}

    # HQ says it under the lockup, and the plane is up: no warning, nothing unreachable.
    {sid, _ws} = local_session!()
    {pid, screen} = start_tui(sid, page: :hq, plane: url)
    eventually(fn -> screen_text(pid, screen) =~ "This plane recommends troupe 99.0.1" end)
    refute screen_text(pid, screen) =~ "unreachable"
    refute screen_text(pid, screen) =~ "⚠"
    GenServer.stop(pid, :normal)
  end

  test "a version at or past the recommended one says nothing" do
    {remote, url} =
      start_remote!(transport: :http, client_versions: %{"tui" => %{"recommended" => @version}})

    login!(remote, url)
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> Client.fleet_status(origin).up? end)
    assert Client.fleet_status(origin)[:suggest] == nil

    me = self()
    assert Troupe.CLI.Remote.whoami(url, say: &send(me, {:said, &1})) == 0
    refute_received {:said, "This plane recommends" <> _}
  end

  test "a plane that does not serve this version refuses it in one sentence, wherever it is asked" do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)

    FakeRemote.client_versions(remote, %{
      "tui" => %{"minimum" => "99.0.0", "recommended" => "99.0.1"}
    })

    # The connection the sign-in made was before the policy; this one is after it.
    detach_all()
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> is_binary(Client.fleet_status(origin).update_required) end)

    sentence = Client.fleet_status(origin).update_required

    assert sentence ==
             "This plane needs troupe 99.0.0 or later, and this is #{@version}: " <>
               "run troupe update, which installs 99.0.1."

    refute Client.fleet_status(origin).up?
    assert {:error, ^sentence} = Client.whoami(origin)

    me = self()
    assert Troupe.CLI.Remote.whoami(url, say: &send(me, {:said, &1})) == 1
    assert_received {:said, ^sentence}

    # HQ says it, and not that the plane is unreachable, which would send somebody off to
    # check their network.
    {sid, _ws} = local_session!()
    {pid, screen} = start_tui(sid, page: :hq, plane: url)
    eventually(fn -> screen_text(pid, screen) =~ "This plane needs troupe 99.0.0 or later" end)
    refute screen_text(pid, screen) =~ "unreachable"
    GenServer.stop(pid, :normal)
  end

  test "a blocked version is refused though it is above the minimum" do
    {remote, url} = start_remote!(transport: :http)
    login!(remote, url)
    FakeRemote.client_versions(remote, %{"tui" => %{"blocked" => [@version]}})

    detach_all()
    {:ok, origin} = Client.connect_plane(url)
    eventually(fn -> is_binary(Client.fleet_status(origin).update_required) end)

    assert Client.fleet_status(origin).update_required ==
             "This plane does not serve troupe #{@version}, which its administrators have " <>
               "blocked: run troupe update."
  end

  describe "troupe update, signed in" do
    # The plane refuses this version, which is when somebody runs troupe update: the call
    # it asks is not the handshake the plane refuses.
    test "asks the plane what each component should be, on its own call" do
      {remote, url} = start_remote!(transport: :http)
      login!(remote, url)

      FakeRemote.client_versions(remote, %{
        "tui" => %{"recommended" => "99.0.1", "minimum" => "99.0.0"},
        "daemon" => %{"blocked" => ["98.0.0"]}
      })

      assert %{url: ^url, versions: answer} = Troupe.CLI.Remote.client_versions()
      assert answer["tui"] == %{"recommended" => "99.0.1", "minimum" => "99.0.0", "blocked" => []}
      assert answer["daemon"]["blocked"] == ["98.0.0"]
      assert Enum.any?(FakeRemote.calls(remote), &match?({"me.client_versions", _}, &1))
    end

    test "goes on as without a plane where the plane has no policy, or none is signed in to" do
      assert Troupe.CLI.Remote.client_versions() == nil

      {remote, url} = start_remote!(transport: :http)
      login!(remote, url)
      assert Troupe.CLI.Remote.client_versions() == nil
    end
  end

  defp local_session! do
    ws = tmp_workspace()

    {sid, _fake, _ws} =
      start_session!(
        workspace: ws,
        script: [{:text, "did the local thing"}, {:finish, "did the local thing"}],
        auto_approve: true
      )

    say!(sid, "a local errand")
    await_done()
    {sid, ws}
  end
end
