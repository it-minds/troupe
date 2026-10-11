defmodule Troupe.Gateway.OrganisationTest do
  @moduledoc """
  The daemon's copy of the organisation's document (#122 slice 2, Decision 869): fetched
  from the plane when a client hands the daemon a plane token, kept by
  `config.organisation` when a client fetched it (`troupe config pull`), announced with
  `config.changed`, and shown by `config.get` with where each value came from. A plane
  that does not answer leaves the copy as it was.
  """

  # The copy is the machine's, in one place for the whole VM.
  use ExUnit.Case, async: false

  alias Troupe.Config.Org
  alias Troupe.Gateway.{Daemon, FakePlane}
  alias Troupe.Protocol.{Client, Endpoint}

  @document %{
    "configured" => true,
    "provider" => "openai",
    "base_url" => "https://llm.example.test/v1",
    "auth" => "bearer",
    "models" => %{"default" => "org-model", "cheap" => nil, "expensive" => nil},
    "defaults" => %{
      "provider" => "openai",
      "base_url" => "https://llm.example.test/v1",
      "auth" => "bearer",
      "models" => %{"default" => "org-model"}
    },
    "enforced" => %{"approvals" => "deny", "max_turns" => 25}
  }

  @vars ~w(TROUPE_CONFIG_HOME TROUPE_STATE_HOME TROUPE_OPENCODE_CONFIG TROUPE_OPENCODE_AUTH TROUPE_API_KEY
           TROUPE_PROVIDER TROUPE_MODEL TROUPE_BASE_URL)

  setup do
    base = Path.join(System.tmp_dir!(), "troupe-gw-org-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "config"))
    File.mkdir_p!(Path.join(base, "state"))

    previous = Map.new(@vars, &{&1, System.get_env(&1)})
    Enum.each(@vars, &System.delete_env/1)
    System.put_env("TROUPE_CONFIG_HOME", Path.join(base, "config"))
    System.put_env("TROUPE_STATE_HOME", Path.join(base, "state"))
    System.put_env("TROUPE_OPENCODE_CONFIG", Path.join(base, "none.jsonc"))
    System.put_env("TROUPE_OPENCODE_AUTH", Path.join(base, "none.json"))
    File.rm(Org.cache_path())

    plane = FakePlane.serve()

    on_exit(fn ->
      Process.exit(plane.server, :normal)
      File.rm(Org.cache_path())

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

    %{plane: plane, client: client, base: base}
  end

  defp link(ctx) do
    Client.call(ctx.client, "identity.link", %{
      "command_id" => Client.command_id(),
      "subject" => "ada@example.test",
      "plane_url" => ctx.plane.url,
      "plane_token" => "plane-token"
    })
  end

  defp keys(client) do
    {:ok, answer} = Client.call(client, "config.get", %{})
    Map.new(answer["keys"], &{&1["key"], &1})
  end

  test "a link with a token fetches the plane's document, keeps it, says so, and config.get shows it",
       ctx do
    FakePlane.client_defaults_with(ctx.plane.state, @document)

    assert {:ok, %{"linked" => true}} = link(ctx)

    assert_receive {:troupe_notification, "config.changed",
                    %{"scope" => "org", "keys" => changed}},
                   5_000

    assert "models.default" in changed
    assert "max_turns" in changed

    assert {:ok, cached} = Org.read_cache()
    assert cached["plane_url"] == ctx.plane.url
    assert cached["enforced"] == %{"approvals" => "deny", "max_turns" => 25}

    keys = keys(ctx.client)

    assert %{"layer" => "org", "source" => source, "value" => "org-model"} =
             keys["models.default"]

    assert source == ctx.plane.url
    assert %{"layer" => "enforced", "value" => 25, "scopes" => []} = keys["max_turns"]

    assert {:error, %{data: %{"reason" => why}}} =
             Client.call(ctx.client, "config.set", %{
               "command_id" => Client.command_id(),
               "key" => "max_turns",
               "value" => 10
             })

    assert why =~ "max_turns is set by your organisation (25, from #{ctx.plane.url})"
  end

  test "a plane that does not answer leaves the copy as it was", ctx do
    {:ok, _kept} =
      Org.save("https://other.example.test", %{
        "defaults" => %{},
        "enforced" => %{"max_depth" => 1}
      })

    assert {:ok, _} = link(ctx)

    assert eventually(fn ->
             Enum.any?(FakePlane.calls(ctx.plane.state), &match?({"me.client_defaults", _}, &1))
           end)

    assert {:ok, %{"plane_url" => "https://other.example.test"}} = Org.read_cache()
  end

  test "config.organisation keeps what a client fetched, and says which keys its own files win on",
       ctx do
    File.write!(
      Path.join([ctx.base, "config", "config.yaml"]),
      "version: 1\nmodels:\n  default: my-model\n"
    )

    assert {:ok, kept} =
             Client.call(ctx.client, "config.organisation", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url <> "/",
               "document" => @document
             })

    assert kept["plane_url"] == ctx.plane.url
    assert kept["enforced"] == %{"approvals" => "deny", "max_turns" => 25}
    assert kept["shadowed"] == ["models.default"]
    assert kept["path"] == Troupe.Paths.display(Org.cache_path())

    assert_receive {:troupe_notification, "config.changed", %{"scope" => "org"}}, 2_000

    # The same document again changes nothing, and says nothing.
    assert {:ok, _kept} =
             Client.call(ctx.client, "config.organisation", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => @document
             })

    refute_receive {:troupe_notification, "config.changed", _}, 300

    assert {:error, %{data: %{"reason" => why}}} =
             Client.call(ctx.client, "config.organisation", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => %{"defaults" => %{}, "enforced" => %{"max_turns" => "lots"}}
             })

    assert why =~ "was not saved"
    assert {:ok, %{"enforced" => %{"max_turns" => 25}}} = Org.read_cache()
  end

  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() -> true
      deadline <= 0 -> false
      true -> Process.sleep(50) && eventually(check, deadline - 50)
    end
  end
end
