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

  require Logger

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
    File.rm(Org.keys_path())

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

  # -- the plane's signing key (#657) -------------------------------------------------

  # What the daemon logs is asserted on here, so it is logged whatever level a suite run
  # before this one left the VM at.
  defp logging_info do
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)
  end

  test "a link pins the plane's key and keeps the document as the plane signed it", ctx do
    fingerprint = FakePlane.sign(ctx.plane.state)
    FakePlane.client_defaults_with(ctx.plane.state, @document)

    assert {:ok, _} = link(ctx)
    assert eventually(fn -> match?({:ok, %{"signed" => _}}, Org.read_cache()) end)

    assert {:ok,
            %{"signed" => %{"fingerprint" => ^fingerprint}, "enforced" => %{"max_turns" => 25}}} =
             Org.read_cache()

    assert {:ok, %{"plane_key" => key}} = Client.call(ctx.client, "identity.get", %{})
    assert key["fingerprint"] == fingerprint
    assert key["plane_url"] == ctx.plane.url
    refute Map.has_key?(key, "offered")
  end

  test "a changed key is refused, the copy before it kept, until the person accepts it by its fingerprint",
       ctx do
    logging_info()
    old = FakePlane.sign(ctx.plane.state)
    FakePlane.client_defaults_with(ctx.plane.state, @document)
    assert {:ok, _} = link(ctx)
    assert eventually(fn -> match?({:ok, %{"signed" => _}}, Org.read_cache()) end)

    # The plane's key rotated, and its limits changed with it.
    new = FakePlane.sign(ctx.plane.state)

    FakePlane.client_defaults_with(
      ctx.plane.state,
      put_in(@document, ["enforced", "max_turns"], 90)
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = link(ctx)

        assert eventually(fn ->
                 Enum.count(
                   FakePlane.calls(ctx.plane.state),
                   &match?({"me.client_defaults", _}, &1)
                 ) == 2
               end)

        Process.sleep(200)
      end)

    assert log =~ "now signs with the key #{new}, not #{old}"
    assert {:ok, %{"enforced" => %{"max_turns" => 25}}} = Org.read_cache()

    assert {:ok, %{"plane_key" => key}} = Client.call(ctx.client, "identity.get", %{})
    assert key["fingerprint"] == old
    assert key["offered"]["fingerprint"] == new

    assert {:error, %{data: %{"reason" => why}}} =
             Client.call(ctx.client, "identity.accept_plane_key", %{
               "command_id" => Client.command_id(),
               "fingerprint" => old <> "x"
             })

    assert why =~ "offers the key #{new}"

    assert {:ok, %{"plane_key" => %{"fingerprint" => ^new}}} =
             Client.call(ctx.client, "identity.accept_plane_key", %{
               "command_id" => Client.command_id(),
               "fingerprint" => new
             })

    assert eventually(fn ->
             match?({:ok, %{"enforced" => %{"max_turns" => 90}}}, Org.read_cache())
           end)
  end

  test "config.organisation refuses a document signed by another key, or changed after it was signed",
       ctx do
    FakePlane.sign(ctx.plane.state)
    FakePlane.client_defaults_with(ctx.plane.state, @document)
    assert {:ok, _} = link(ctx)
    assert eventually(fn -> match?({:ok, %{"signed" => _}}, Org.read_cache()) end)

    {public, secret} = :crypto.generate_key(:eddsa, :ed25519)
    alias Troupe.Protocol.PlaneSignature
    lifted = put_in(@document, ["enforced", "max_turns"], 900)
    text = PlaneSignature.document("client_defaults", lifted)
    signature = :crypto.sign(:eddsa, :none, text, [secret, :ed25519])

    forged =
      Map.put(
        lifted,
        "signed",
        PlaneSignature.envelope(text, signature, PlaneSignature.fingerprint(public))
      )

    assert {:error, %{data: %{"reason" => why}}} =
             Client.call(ctx.client, "config.organisation", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => forged
             })

    assert why =~ "is signed by the key #{PlaneSignature.fingerprint(public)}"

    assert {:error, %{data: %{"reason" => unsigned}}} =
             Client.call(ctx.client, "config.organisation", %{
               "command_id" => Client.command_id(),
               "plane_url" => ctx.plane.url,
               "document" => lifted
             })

    assert unsigned =~ "is not signed"
    assert {:ok, %{"enforced" => %{"max_turns" => 25}}} = Org.read_cache()
  end

  test "a plane that signs nothing has its document kept as it always was, and that said", ctx do
    logging_info()
    FakePlane.client_defaults_with(ctx.plane.state, @document)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, _} = link(ctx)
        assert eventually(fn -> match?({:ok, %{"plane_url" => _}}, Org.read_cache()) end)
      end)

    assert log =~ "signs nothing it tells clients"
    refute Map.has_key?(elem(Org.read_cache(), 1), "signed")
    assert {:ok, identity} = Client.call(ctx.client, "identity.get", %{})
    refute Map.has_key?(identity, "plane_key")
  end

  defp eventually(check, deadline \\ 5_000) do
    cond do
      check.() -> true
      deadline <= 0 -> false
      true -> Process.sleep(50) && eventually(check, deadline - 50)
    end
  end
end
