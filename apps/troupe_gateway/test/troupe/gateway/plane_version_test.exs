defmodule Troupe.Gateway.PlaneVersionTest do
  @moduledoc """
  The daemon's plane link and the plane's version policy (#66 slice 1b, Decision 868).

  A link with a token is followed by the plane's `initialize`, as `troupe-daemon`. A plane
  that refuses this version with `update_required` is asked nothing more until a later
  handshake is answered otherwise, and the refusal is one sentence — in the log and in
  `identity.get` — that says what to run. A plane from before the policy has no
  `initialize` and holds the daemon to nothing.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Troupe.Gateway.{Daemon, FakePlane, Plane}
  alias Troupe.LLM.Identify
  alias Troupe.Protocol.{Client, Endpoint}

  @refusal %{
    "component" => "daemon",
    "version" => "0.12.0-beta",
    "minimum" => "0.13.0-beta",
    "recommended" => "0.13.1-beta",
    "blocked" => false,
    "run" => "troupe update",
    "reason" => "whatever this plane wrote"
  }

  setup do
    plane = FakePlane.serve()
    on_exit(fn -> Process.exit(plane.server, :normal) end)
    %{plane: plane}
  end

  describe "the handshake" do
    setup %{plane: plane} do
      name = :"plane-#{System.unique_integer([:positive])}"
      start_supervised!({Plane, name: name})

      :ok =
        Plane.link(
          %{
            "subject" => "ada@example.test",
            "plane_url" => plane.url,
            "plane_token" => "plane-token"
          },
          name
        )

      %{name: name}
    end

    test "a refusal is one sentence saying what to run, and nothing more reaches the plane",
         %{plane: plane, name: name} do
      FakePlane.initialize_with(plane.state, {:refuse, @refusal})

      log =
        capture_log(fn ->
          assert {:error, {:update_required, sentence}} = Plane.handshake(name, "0.12.0-beta")
          send(self(), {:sentence, sentence})
        end)

      assert_received {:sentence, sentence}

      assert sentence ==
               "This plane needs troupe-daemon 0.13.0-beta or later, and this is 0.12.0-beta: " <>
                 "run troupe update, which installs 0.13.1-beta."

      assert log =~ sentence
      assert Plane.refusal(name) == sentence

      # Asked of nobody: the refusal answers for the plane.
      assert {:error, {:update_required, ^sentence}} =
               Plane.call("session.erasures", %{"device" => "laptop"}, name)

      assert [{"initialize", hello}] = FakePlane.calls(plane.state)
      # With the platform, for the plane's record of who runs what (#657).
      assert hello["client_info"] == %{
               "name" => "troupe-daemon",
               "version" => "0.12.0-beta",
               "platform" => Identify.platform()
             }
    end

    test "a later handshake the plane answers lifts it", %{plane: plane, name: name} do
      FakePlane.initialize_with(plane.state, {:refuse, @refusal})
      capture_log(fn -> {:error, _} = Plane.handshake(name, "0.12.0-beta") end)

      # A token renewed is a link again, and the refusal stands until the plane says so.
      :ok = Plane.link(%{"plane_token" => "plane-token"}, name)
      assert is_binary(Plane.refusal(name))

      FakePlane.initialize_with(plane.state, {:ok, %{"client_update" => nil}})
      assert :ok = Plane.handshake(name, "0.13.1-beta")
      assert Plane.refusal(name) == nil

      assert {:ok, %{"erasures" => []}} =
               Plane.call("session.erasures", %{"device" => "laptop"}, name)
    end

    test "a plane from before the policy holds the daemon to nothing", %{plane: plane, name: name} do
      assert :ok = Plane.handshake(name, "0.12.0-beta")
      assert Plane.refusal(name) == nil

      assert {:ok, %{"erasures" => []}} =
               Plane.call("session.erasures", %{"device" => "laptop"}, name)

      assert [{"initialize", _}, {"session.erasures", _}] = FakePlane.calls(plane.state)
    end

    test "unlinking forgets a refusal with the plane it came from", %{plane: plane, name: name} do
      FakePlane.initialize_with(plane.state, {:refuse, @refusal})
      capture_log(fn -> {:error, _} = Plane.handshake(name, "0.12.0-beta") end)

      :ok = Plane.unlink(name)
      assert Plane.refusal(name) == nil
    end
  end

  describe "through the daemon" do
    setup do
      base = Path.join(System.tmp_dir!(), "troupe-planever-#{System.unique_integer([:positive])}")
      state_dir = Path.join(base, "state")
      File.mkdir_p!(state_dir)

      previous = System.get_env("TROUPE_STATE_HOME")
      System.put_env("TROUPE_STATE_HOME", state_dir)

      endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
      start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

      on_exit(fn ->
        if previous,
          do: System.put_env("TROUPE_STATE_HOME", previous),
          else: System.delete_env("TROUPE_STATE_HOME")

        File.rm_rf!(base)
      end)

      %{endpoint: endpoint}
    end

    test "a link with a token to a plane that refuses this version asks nothing more, and identity.get says why",
         ctx do
      FakePlane.initialize_with(ctx.plane.state, {:refuse, @refusal})

      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      link = %{
        "command_id" => Client.command_id(),
        "subject" => "ada@example.test",
        "plane_url" => ctx.plane.url,
        "plane_token" => "plane-token"
      }

      capture_log(fn ->
        assert {:ok, %{"linked" => true}} = Client.call(client, "identity.link", link)

        assert eventually(fn ->
                 match?(
                   {:ok, %{"update_required" => _}},
                   Client.call(client, "identity.get", %{})
                 )
               end)
      end)

      assert {:ok, %{"update_required" => sentence}} = Client.call(client, "identity.get", %{})
      assert sentence =~ "troupe-daemon 0.13.0-beta or later"
      assert sentence =~ "run troupe update"

      # The plane was asked its word on this version, and nothing after it: no erasures
      # asked for, nothing registered.
      assert [{"initialize", %{"client_info" => %{"name" => "troupe-daemon"}}}] =
               FakePlane.calls(ctx.plane.state)
    end

    test "a link to a plane that serves this version asks for erasures, as before", ctx do
      FakePlane.initialize_with(ctx.plane.state, {:ok, %{"client_update" => nil}})

      {:ok, client} = Troupe.Protocol.Daemon.connect(endpoint: ctx.endpoint, spawn: false)
      on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

      link = %{
        "command_id" => Client.command_id(),
        "subject" => "ada@example.test",
        "plane_url" => ctx.plane.url,
        "plane_token" => "plane-token"
      }

      assert {:ok, _identity} = Client.call(client, "identity.link", link)

      assert eventually(fn ->
               Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"session.erasures", _}, &1))
             end)

      assert {:ok, identity} = Client.call(client, "identity.get", %{})
      refute Map.has_key?(identity, "update_required")
    end
  end

  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() -> true
      deadline <= 0 -> false
      true -> Process.sleep(50) && eventually(check, deadline - 50)
    end
  end
end
