defmodule Troupe.Gateway.ProfileGetTest do
  @moduledoc """
  What a profile gives a session, read through the daemon: `profile.get` is the plane's,
  sent on as the daemon's person with the arguments the plane takes, its answer with
  `plane_url` and its refusal under the plane's own code; signed out, a sentence; and to a
  client in Local only, refused, since the daemon asks the plane nothing for it. Against
  `FakePlane`.
  """

  use ExUnit.Case, async: false

  alias Troupe.Gateway.{Daemon, Dispatch, FakePlane}
  alias Troupe.Protocol.{Client, Endpoint}

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-profile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))

    plane = FakePlane.serve()

    on_exit(fn ->
      Process.exit(plane.server, :normal)

      Enum.each(previous, fn {k, v} ->
        if v, do: System.put_env(k, v), else: System.delete_env(k)
      end)

      File.rm_rf!(base)
    end)

    endpoint = %Endpoint{kind: :unix, path: Path.join(base, "daemon.sock")}
    start_supervised!({Daemon, endpoint: endpoint, idle_shutdown_ms: :timer.hours(1)})

    %{plane: plane, endpoint: endpoint, client: connect(endpoint, nil)}
  end

  test "profile.get is a method the daemon forwards, with observe" do
    assert Dispatch.methods()["profile.get"] == :observe
  end

  test "it is the plane's answer as the person, its refusal kept, and a sentence signed out",
       ctx do
    assert {:error, %{message: "unavailable", data: %{"reason" => reason}}} =
             Client.call(ctx.client, "profile.get", %{"name" => "dev"})

    assert reason =~ "not signed in to a Troupe plane"
    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"profile.get", _}, &1))

    assert {:ok, %{"linked" => true}} = link(ctx)

    assert {:ok, %{"name" => "dev", "team" => "engineering", "plane_url" => url}} =
             Client.call(ctx.client, "profile.get", %{
               "name" => "dev",
               "team" => "engineering",
               "x" => 1
             })

    assert url == ctx.plane.url

    # Only the arguments the plane takes go on.
    assert {"profile.get", %{"name" => "dev", "team" => "engineering"} = sent} =
             Enum.find(FakePlane.calls(ctx.plane.state), &match?({"profile.get", _}, &1))

    refute Map.has_key?(sent, "x")

    assert {:error, %{message: "not_found", data: %{"profile" => "secret"}}} =
             Client.call(ctx.client, "profile.get", %{"name" => "secret"})
  end

  test "a client in Local only is refused it, and the plane is asked nothing", ctx do
    assert {:ok, %{"linked" => true}} = link(ctx)

    local =
      connect(ctx.endpoint, %{"name" => "troupe-gui", "version" => "1", "local_only" => true})

    assert {:error, %{message: "forbidden", data: %{"reason" => reason}}} =
             Client.call(local, "profile.get", %{"name" => "dev"})

    assert reason =~ "Local only"
    refute Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"profile.get", _}, &1))
  end

  defp link(ctx) do
    Client.call(ctx.client, "identity.link", %{
      "command_id" => Client.command_id(),
      "subject" => "ada@example.test",
      "plane_url" => ctx.plane.url,
      "plane_token" => "plane-token"
    })
  end

  defp connect(endpoint, client_info) do
    options = [endpoint: endpoint, spawn: false, owner: self()]
    options = if client_info, do: Keyword.put(options, :client_info, client_info), else: options
    {:ok, client} = Troupe.Protocol.Daemon.connect(options)
    on_exit(fn -> if Process.alive?(client), do: Client.close(client) end)
    client
  end
end
