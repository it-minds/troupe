defmodule Troupe.Gateway.PolicyTest do
  @moduledoc """
  The plane's word on this machine kept up to date while it is signed in (#657): the
  daemon's poll asks the plane's `initialize` again, and where its `policy.revision` moved,
  fetches the two signed answers. A changed organisation's document is kept, told to every
  client and given to every session running here for its next turn; a changed version
  policy is told to every client. An unchanged revision fetches nothing, and a refusal of
  this version is taken only as the plane signed it.
  """

  use ExUnit.Case, async: false

  alias Troupe.Config.Org
  alias Troupe.Gateway.{Daemon, FakePlane, Plane, Policy}
  alias Troupe.LLM.Fake
  alias Troupe.Protocol.{Client, Endpoint}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  @versions %{
    "versions" => %{
      "tui" => %{"recommended" => nil, "minimum" => nil, "blocked" => []},
      "daemon" => %{"recommended" => nil, "minimum" => nil, "blocked" => []},
      "desktop" => %{"recommended" => "0.24.0-beta", "minimum" => nil, "blocked" => []}
    },
    "release" => %{"url" => nil}
  }

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-policy-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    Enum.each(["config", "state", "workspace"], &File.mkdir_p!(Path.join(base, &1)))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))
    File.rm(Org.cache_path())
    File.rm(Org.keys_path())

    plane = FakePlane.serve()
    FakePlane.sign(plane.state)
    FakePlane.initialize_with(plane.state, {:ok, %{"protocol_version" => "1"}})
    FakePlane.client_defaults_with(plane.state, document(4000))
    FakePlane.client_versions_with(plane.state, @versions)

    on_exit(fn ->
      Process.exit(plane.server, :normal)
      File.rm(Org.cache_path())
      File.rm(Org.keys_path())

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    {:ok, client} =
      Troupe.Protocol.Daemon.connect(endpoint: endpoint, spawn: false, owner: self())

    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)

    {:ok, %{"linked" => true}} =
      Client.call(client, "identity.link", %{
        "command_id" => Client.command_id(),
        "subject" => "ada@example.test",
        "plane_url" => plane.url,
        "plane_token" => "plane-token"
      })

    # The link keeps the document as it stands, which every later poll is compared with.
    assert_receive {:troupe_notification, "config.changed", %{"scope" => "org"}}, 20_000
    assert eventually(fn -> match?({:ok, %{"signed" => _}}, Org.read_cache()) end)
    _first = Policy.poll()

    %{plane: plane, client: client, workspace: workspace}
  end

  defp document(max_tokens),
    do: %{"defaults" => %{}, "enforced" => %{"max_tokens" => max_tokens}}

  defp calls(plane, method),
    do: plane.state |> FakePlane.calls() |> Enum.count(&match?({^method, _}, &1))

  test "a limit changed on the plane reaches a running session at its next turn, and every client hears it",
       ctx do
    fake =
      start_supervised!(
        {Fake, [steps: [{:text, "one"}, {:text, "two"}]]},
        id: {Fake, System.unique_integer([:positive])}
      )

    {:ok, session} =
      Troupe.start_session(
        workspace: ctx.workspace,
        fake: fake,
        config_overrides: [provider: "fake", auto_approve: true, model: "fake"]
      )

    on_exit(fn -> Troupe.stop_session(session.id) end)
    :ok = Troupe.subscribe(session.id)
    turn(session.id, "first")
    assert [%{max_tokens: 4000}] = Fake.requests(fake)

    FakePlane.client_defaults_with(ctx.plane.state, document(1000))
    assert :org in Policy.poll()

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "org", "keys" => ["max_tokens"]}},
                   5_000

    turn(session.id, "second")
    assert [_first, %{max_tokens: 1000}] = Fake.requests(fake)

    assert [%{data: %{"key" => "organisation", "message" => message}}] =
             session.id |> Troupe.events() |> Enum.filter(&(&1.type == "config_note"))

    assert message == "Your organisation's settings changed: max_tokens holds from this turn."
  end

  test "a version policy changed on the plane is told to every client; an unchanged one fetches nothing",
       ctx do
    before = calls(ctx.plane, "me.client_versions")
    assert Policy.poll() == []
    assert calls(ctx.plane, "me.client_versions") == before

    FakePlane.client_versions_with(
      ctx.plane.state,
      put_in(@versions, ["versions", "desktop", "minimum"], "0.24.0-beta")
    )

    assert Policy.poll() == [:versions]

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "versions", "keys" => ["versions.desktop.minimum"]}},
                   5_000
  end

  test "a refusal of this version is taken only as the plane signed it", ctx do
    refusal = %{
      "component" => "daemon",
      "version" => version(),
      "minimum" => "99.0.0",
      "recommended" => "99.0.0",
      "blocked" => false,
      "run" => "troupe update"
    }

    FakePlane.initialize_with(ctx.plane.state, {:refuse_unsigned, refusal})
    Policy.poll()
    assert Plane.refusal() == nil

    FakePlane.initialize_with(ctx.plane.state, {:refuse, refusal})
    Policy.poll()
    assert Plane.refusal() =~ "This plane needs troupe-daemon 99.0.0 or later"

    {:ok, identity} = Client.call(ctx.client, "identity.get", %{})
    assert identity["update_required"] =~ "troupe-daemon 99.0.0 or later"
  end

  defp version, do: to_string(Application.spec(:troupe_gateway, :vsn) || "dev")

  defp turn(sid, text) do
    Troupe.send_input(sid, text)
    await_idle(sid)
  end

  defp await_idle(sid) do
    receive do
      {:troupe_event, ^sid, %{type: "agent_state", agent: ["root"], data: %{"state" => "idle"}}} ->
        :ok

      {:troupe_event, ^sid, _other} ->
        await_idle(sid)
    after
      10_000 -> flunk("the session did not finish its turn")
    end
  end

  defp eventually(check, deadline \\ 20_000) do
    cond do
      check.() -> true
      deadline <= 0 -> false
      true -> Process.sleep(50) && eventually(check, deadline - 50)
    end
  end
end
