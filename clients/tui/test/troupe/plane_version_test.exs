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
               {"initialize",
                %{
                  "client_info" => %{
                    "name" => "troupe",
                    "version" => @version,
                    # Where it runs, as the daemon's own handshake says it (D134).
                    "platform" => "" <> _
                  }
                }},
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

  # #657: the plane signs its version policy with a key of its own, pinned at sign-in.
  describe "the plane's signing key" do
    test "is pinned at sign-in, and the policy is taken as the plane signed it, with where releases are" do
      {remote, url} = start_remote!(transport: :http)
      fingerprint = FakeRemote.sign(remote)
      lines = login!(remote, url)

      assert "the plane signs what it tells clients with the key #{fingerprint}; pinned" in lines

      FakeRemote.client_versions(remote, %{"tui" => %{"recommended" => "99.0.1"}})
      FakeRemote.release_url(remote, "https://mirror.example.test/troupe")

      assert %{versions: versions, release_url: "https://mirror.example.test/troupe"} =
               Troupe.CLI.Remote.client_versions(say: &send(self(), {:said, &1}))

      assert versions["tui"]["recommended"] == "99.0.1"
      refute Map.has_key?(versions, "release")
      refute_received {:said, _}
    end

    test "a policy signed by another key is refused until the person accepts the new one by its fingerprint" do
      {remote, url} = start_remote!(transport: :http)
      old = FakeRemote.sign(remote)
      login!(remote, url)
      FakeRemote.client_versions(remote, %{"tui" => %{"recommended" => "99.0.1"}})

      new = FakeRemote.sign(remote)
      me = self()
      say = &send(me, {:said, &1})

      assert Troupe.CLI.Remote.client_versions(say: say) == nil
      assert_received {:said, refused}
      assert refused =~ "the version policy from #{url} is signed by the key #{new}, not by #{old}"
      assert refused =~ "troupe plane-key accept #{new}"
      assert refused =~ "going on as without a plane"

      assert Troupe.CLI.Remote.plane_key(nil, say: say) == 1
      assert_received {:said, pinned}
      assert pinned =~ "signs with the key #{old}"
      assert_received {:said, offered}
      assert offered =~ "it now offers the key #{new} instead"

      assert Troupe.CLI.Remote.accept_plane_key(old <> "x", nil, say: say) == 1
      assert_received {:said, _not_that_one}

      assert Troupe.CLI.Remote.accept_plane_key(new, nil, say: say) == 0
      assert_received {:said, accepted}
      assert accepted =~ "the key #{new} is pinned for #{url}"

      assert %{versions: %{"tui" => %{"recommended" => "99.0.1"}}} =
               Troupe.CLI.Remote.client_versions(say: say)
    end

    test "a refusal of this version is taken as the pinned key signed it, and an unsigned one is not" do
      {remote, url} = start_remote!(transport: :http)
      FakeRemote.sign(remote)
      login!(remote, url)

      FakeRemote.client_versions(remote, %{
        "tui" => %{"minimum" => "99.0.0", "recommended" => "99.0.1"}
      })

      detach_all()
      {:ok, origin} = Client.connect_plane(url)
      eventually(fn -> is_binary(Client.fleet_status(origin).update_required) end)

      assert Client.fleet_status(origin).update_required =~
               "This plane needs troupe 99.0.0 or later"

      # The same refusal, unsigned, from a plane whose key this machine pinned: not the
      # plane's word, so nothing says to update, and the plane is not up either.
      FakeRemote.unsigned_refusals(remote)
      detach_all()
      {:ok, origin} = Client.connect_plane(url)

      eventually(fn -> match?({:initialize, _why}, Client.fleet_status(origin).error) end)
      status = Client.fleet_status(origin)
      {:initialize, why} = status.error
      assert why =~ "the plane's refusal of this version from #{url} is not signed"
      assert status.update_required == nil
      refute status.up?
    end

    test "a plane that signs nothing is said so at sign-in, and its policy taken as it is" do
      {remote, url} = start_remote!(transport: :http)
      lines = login!(remote, url)
      assert "the plane signs nothing it tells clients (a plane from before 0.22)" in lines

      FakeRemote.client_versions(remote, %{"tui" => %{"recommended" => "99.0.1"}})
      me = self()

      assert %{versions: %{"tui" => _}, release_url: nil} =
               Troupe.CLI.Remote.client_versions(say: &send(me, {:said, &1}))

      assert_received {:said, line}
      assert line =~ "signs nothing it tells clients"
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
