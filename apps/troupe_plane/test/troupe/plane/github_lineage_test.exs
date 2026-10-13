defmodule Troupe.Plane.GitHubLineageTest do
  @moduledoc """
  A sibling and a fork start on their parent's repository (D126): `session.spawn` and
  `session.fork` carry `repository` over, checked against the plane's App and the profile
  the new session starts on as `session.create` checks one, and handed to its pod on
  activation like any other session's.

  Against the development OpenBao's transit engine, as `Troupe.Plane.GitHubTest` is: the
  App's key is imported there, and a fake GitHub (`Troupe.Plane.FakeGitHub`) holds the
  installation.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.Plane.{Admin, FakeGitHub, FakePod, Fleet, Harness, Sessions}
  alias Troupe.Plane.Control.{Connections, Listener}

  @moduletag timeout: 120_000

  @app_id 4343
  @installation 77_002

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @wanted %{"owner" => "example-org", "name" => "widgets", "ref" => "main"}

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")

    name = "troupe-github-lineage-test-#{System.unique_integer([:positive])}"
    transit = Application.get_env(:troupe_plane, :transit, [])
    Application.put_env(:troupe_plane, :transit, Keyword.put(transit, :github_key, name))

    on_exit(fn ->
      Application.put_env(:troupe_plane, :transit, transit)
      delete_transit_key(transit, name)
    end)

    fake = FakeGitHub.start()
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    FakeGitHub.app(fake, @app_id, key)
    FakeGitHub.install(fake, @installation, @app_id, "example-org", ["widgets"])

    {:ok, _} =
      Fleet.put_profile(%{name: "dev", spec: %{"egress" => %{"gitHosts" => [fake.host]}}})

    {:ok, _} =
      Admin.github_put(@root, %{
        "app_id" => @app_id,
        "api_url" => fake.api_url,
        "installations" => [%{"owner" => "example-org", "installation_id" => @installation}],
        "private_key" =>
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
      })

    start_supervised!({Registry, keys: :duplicate, name: Troupe.Plane.Control.Registry})
    start_supervised!(Connections)
    start_supervised!(Troupe.Plane.Singleton)
    start_supervised!({Listener, port: 0, verify: &FakePod.verify/1})

    team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
    ada = person("ada@example.test", ["engineering"])
    _pod = FakePod.enrol(Listener.port(), "dev-token", "troupe-w-dev-0")

    %{team: team, ada: ada, as_ada: %{user: ada, platform_admin?: false}}
  end

  test "a sibling starts on its parent's repository", context do
    assert {:ok, %{"session_id" => parent}} =
             Harness.call(
               "session.create",
               %{"profile" => "dev", "visibility" => "team", "repository" => @wanted},
               context.as_ada
             )

    assert_receive {:pushed, "session.activate", %{"session_id" => ^parent}}, 5_000

    assert {:ok, %{"session_id" => sibling}} =
             Harness.call(
               "session.spawn",
               %{"parent" => parent, "prompt" => "go on"},
               context.as_ada
             )

    assert Sessions.get(sibling).repository == @wanted
    assert_receive {:pushed, "session.activate", %{"session_id" => ^sibling} = params}, 5_000
    assert params["repository"] == @wanted
  end

  test "a fork starts on its parent's repository", context do
    {:ok, parent} =
      Sessions.create(%{
        id: "s-lineage-#{System.unique_integer([:positive])}",
        owner_id: context.ada.id,
        owner_subject: context.ada.subject,
        team_id: context.team.id,
        profile: "dev",
        visibility: "private",
        state: "active",
        epoch: 1,
        repository: @wanted
      })

    {:ok, _} = Sessions.seal(parent.id, %{last_seq: 12, head_hash: "sha256:whatever"})

    assert {:ok, %{"session_id" => fork}} =
             Harness.call("session.fork", %{"session_id" => parent.id}, context.as_ada)

    assert Sessions.get(fork).repository == @wanted
    assert_receive {:pushed, "session.activate", %{"session_id" => ^fork} = params}, 5_000
    assert params["repository"] == @wanted
  end

  # -- the development OpenBao, with the root token ---------------------------------

  defp delete_transit_key(transit, name) do
    mount = transit[:mount] || "transit"

    Req.request(
      method: :post,
      url: "#{transit[:address]}/v1/#{mount}/keys/#{name}/config",
      headers: [{"x-vault-token", transit[:token]}],
      json: %{"deletion_allowed" => true},
      retry: false
    )

    Req.request(
      method: :delete,
      url: "#{transit[:address]}/v1/#{mount}/keys/#{name}",
      headers: [{"x-vault-token", transit[:token]}],
      retry: false
    )
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    is_binary(address) and
      match?({:ok, %{status: 200}}, Req.request(url: address <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end
end
