defmodule Troupe.Plane.PersonCredentialsTest do
  @moduledoc """
  A credential that belongs to a person, proven against a real OpenBao.

  The claim is a negative one and cannot be checked against a double: a pod running
  Ada's session may read Ada's slots and no one else's, and the thing that decides it is
  OpenBao rather than any code in this repository. So this stands the real mechanism up —
  the plane signs an assertion through transit, OpenBao's JWT auth method verifies it
  against the transit key's public half, and the policy it issues is templated on the
  subject that assertion carried — and then asks for somebody else's slot.

  The plane never holds the value. Nothing here writes one through the plane, and the
  last test is the reason: the plane's own credential cannot read a slot even when it
  knows exactly where it is.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.KMS.{OpenBao, Policy}
  alias Troupe.Plane.{Bundles, Fleet, Harness, Identity, Login, PersonAuth, Tokens}
  alias Troupe.Protocol.SessionId

  @moduletag timeout: 60_000

  @auth_path "jwt-people"
  @role "troupe-person"
  @issuer "https://plane.test.invalid"

  setup_all do
    if reachable?() do
      Application.put_env(:troupe_plane, :issuer, @issuer)
      on_exit(fn -> Application.delete_env(:troupe_plane, :issuer) end)

      case PersonAuth.configure(@auth_path, @role, @issuer) do
        :ok -> :ok
        {:error, reason} -> {:ok, skip: "could not configure JWT auth: #{inspect(reason)}"}
      end
    else
      IO.puts(:stderr, """

      SKIPPED: no OpenBao (#{address()}).
      Bring one up with `scripts/dev-up`.
      """)

      {:ok, skip: "no OpenBao"}
    end
  end

  setup context do
    if context[:skip], do: :ok, else: :ok
  end

  describe "an assertion the plane minted" do
    test "reads that person's slot and is refused everybody else's", context do
      requires_bao(context)

      ada = "idp|ada-#{unique()}"
      bo = "idp|bo-#{unique()}"

      write_slot(ada, "jira", "ada's jira token")
      write_slot(bo, "jira", "bo's jira token")

      assert {:ok, assertion, claims} = Tokens.mint_kms_assertion(ada)
      assert claims["sub"] == ada
      assert claims["aud"] == Tokens.kms_audience()
      # A minute, because the pod exchanges it once and then holds the token it got.
      assert claims["exp"] - claims["iat"] == 60

      assert {:ok, %{token: token}} = OpenBao.jwt_login(address(), @auth_path, @role, assertion)

      assert {:ok, "ada's jira token"} = read_slot(token, ada, "jira")

      # The whole point. The pod holding this token is running Ada's session; Bo's slot
      # is not something it can ask for, and the refusal comes from OpenBao.
      assert {:error, :forbidden} = read_slot(token, bo, "jira")

      # Nor can it reach a team's session key, which is the other subtree.
      assert {:error, :forbidden} = read_data(token, "troupe/teams/engineering/sessions/s-1")
    end

    test "a session token is not an assertion, whatever it says inside", context do
      requires_bao(context)

      ada = "idp|ada-#{unique()}"

      # The same signer, the same subject, a pod's audience: this is what a session token
      # looks like, and the role's `bound_audiences` is what stops it being spent here.
      # One token that worked in two places would be a token that works in the second
      # when the first is compromised.
      assert {:ok, session_token, _claims} =
               Tokens.mint(%{"sub" => ada}, audience: "troupe-w-dev-0")

      assert {:error, _} = OpenBao.jwt_login(address(), @auth_path, @role, session_token)
    end

    test "the plane cannot read a slot, knowing exactly where it is", context do
      requires_bao(context)

      ada = "idp|ada-#{unique()}"
      write_slot(ada, "jira", "ada's jira token")

      plane = token_for(Policy.plane(mount()))

      # "The plane never holds the value" (Decisions 375 and 377) is this, checked against
      # OpenBao rather than against our belief about our own code. The plane can destroy
      # a person's key metadata, because erasure has to work, and it can read nothing.
      assert {:error, :forbidden} = read_slot(plane, ada, "jira")
    end
  end

  describe "what a person is told about their own connections" do
    setup context do
      requires_bao(context)

      team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      # A subject of its own per test: the database is sandboxed and the key manager is
      # not, so two tests sharing a subject would share a slot — and one of them writing
      # to it would decide what the other sees.
      ada = person("ada-#{unique()}@example.test", ["engineering"])

      {:ok, _} =
        Fleet.put_profile(%{
          name: "dev",
          config_bundle_channel: "stable",
          replicas: 1
        })

      {:ok, _bundle} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "mcp_servers" => [
              %{
                "name" => "jira",
                "url" => "https://mcp.jira.example/mcp",
                "credential_mode" => "person"
              },
              %{
                "name" => "shared",
                "url" => "https://mcp.shared.example/mcp",
                "credential_ref" => "SHARED_TOKEN"
              }
            ]
          },
          announce: false
        )

      %{team: team, ada: ada}
    end

    test "lists the servers that act as them, and whether they have connected", context do
      assert {:ok, %{"connections" => [jira]}} =
               Harness.call("me.connections.list", %{}, as(context.ada))

      # Only the person-mode one: a shared server is nobody's to connect.
      assert jira["server"] == "jira"
      assert jira["slot"] == "jira"
      assert jira["profile"] == "dev"
      refute jira["connected"]

      write_slot(context.ada.subject, "jira", "ada's jira token")

      assert {:ok, %{"connections" => [connected]}} =
               Harness.call("me.connections.list", %{}, as(context.ada))

      assert connected["connected"]
    end

    test "grants an assertion and never a value", context do
      assert {:ok, grant} =
               Harness.call("me.connections.grant", %{"slot" => "jira"}, as(context.ada))

      # No value in, no value out. What crosses is a signed statement of who the caller
      # is, which the plane is entitled to make because it authenticated them.
      assert %{"sub" => subject} = payload_of(grant["assertion"])
      assert subject == context.ada.subject
      assert grant["key_manager"]["path"] == "troupe/people/#{context.ada.subject}/mcp/jira"

      refute Enum.any?(Map.values(grant), &(is_binary(&1) and &1 =~ "ada's"))

      # And it is spendable: the client exchanges it itself, and what it gets can write
      # its own slot and read nothing of anybody else's.
      assert {:ok, %{token: token}} =
               OpenBao.jwt_login(address(), @auth_path, @role, grant["assertion"])

      :ok =
        put("/v1/#{mount()}/data/#{encode(grant["key_manager"]["path"])}", %{
          "data" => %{"value" => "written-by-the-client"}
        })

      assert {:ok, "written-by-the-client"} = read_slot(token, context.ada.subject, "jira")
    end

    test "refuses a slot no server on the caller's profiles asks for", context do
      assert {:error, error} =
               Harness.call("me.connections.grant", %{"slot" => "elsewhere"}, as(context.ada))

      assert error.message == "not_found"
      assert error.data.reason =~ "no server on your profiles"
      assert error.data.slots == ["jira"]
    end
  end

  # Decision 755. A person moved to another claim (751) kept everything the plane holds and
  # lost everything the key manager holds, because the key manager's name for them was
  # their subject and the plane, which cannot read or write that subtree, had moved the
  # subject. The name is now theirs for good.
  describe "a person moved to another claim" do
    setup context do
      requires_bao(context)

      _team = team_with_grant("engineering", "dev", name: "engineering", budget_micros: 0)
      {:ok, _} = Fleet.put_profile(%{name: "dev", config_bundle_channel: "stable", replicas: 1})

      {:ok, _bundle} =
        Bundles.publish(
          "stable",
          %{
            "schema" => 1,
            "mcp_servers" => [
              %{
                "name" => "jira",
                "url" => "https://mcp.jira.example/mcp",
                "credential_mode" => "person"
              }
            ]
          },
          announce: false
        )

      previous = Application.get_env(:troupe_plane, :oidc)
      on_exit(fn -> restore(:oidc, previous) end)

      # Entra-shaped: a pairwise `sub` the plane knew her by, and the `oid` it is switched
      # to. Unique per run, because the key manager is not sandboxed as the database is.
      claims = %{
        "sub" => "pairwise-#{unique()}",
        "oid" => "oid-#{unique()}",
        "email" => "ada@example.test",
        "groups" => ["engineering"]
      }

      {:ok, ada, _teams} = Login.from_claims(claims)

      %{ada: ada, claims: claims, oidc: previous || []}
    end

    test "finds her credential and her private session's key where she left them", context do
      %{ada: ada, claims: claims} = context

      # Before the switch she connects Jira, as a client does: the grant, the exchange, and
      # a write of her own.
      assert {:ok, grant} = Harness.call("me.connections.grant", %{"slot" => "jira"}, as(ada))
      token = exchange(grant["assertion"])
      :ok = write_with(token, grant["key_manager"]["path"], %{"value" => "ada's jira token"})

      # And her laptop seals a private session, whose key it makes where the plane says.
      session_id = SessionId.generate()

      assert {:ok, _row} =
               Harness.call(
                 "session.register",
                 %{"session_id" => session_id, "device" => "laptop"},
                 as(ada)
               )

      assert {:ok, sealing} =
               Harness.call("session.assertion", %{"session_id" => session_id}, as(ada))

      key = Base.encode64(:crypto.strong_rand_bytes(32))

      :ok =
        write_with(exchange(sealing["assertion"]), sealing["key_manager"]["path"], %{"key" => key})

      # The deployment switches to `oid`, and her next sign-in moves her.
      Application.put_env(:troupe_plane, :oidc, Keyword.put(context.oidc, :subject_claim, "oid"))
      assert {:ok, moved, _teams} = Login.from_claims(claims)
      assert moved.id == ada.id
      assert moved.subject == claims["oid"]

      # Her name at the key manager is the one she had: what a client is answered for her
      # names it, and the assertion it spends is for it.
      assert {:ok, %{"connections" => [jira]}} =
               Harness.call("me.connections.list", %{}, as(moved))

      assert jira["connected"]

      assert {:ok, again} = Harness.call("me.connections.grant", %{"slot" => "jira"}, as(moved))
      assert again["key_manager"]["name"] == claims["sub"]
      assert again["key_manager"]["path"] == grant["key_manager"]["path"]
      assert %{"sub" => sub} = payload_of(again["assertion"])
      assert sub == claims["sub"]

      assert {:ok, "ada's jira token"} =
               read_data(exchange(again["assertion"]), again["key_manager"]["path"])

      # Another device restoring the session is told the same name, and gets the key the
      # laptop sealed with rather than making a second one.
      assert {:ok, restoring} =
               Harness.call("session.assertion", %{"session_id" => session_id}, as(moved))

      assert restoring["key_manager"]["name"] == claims["sub"]

      assert {:ok, ^key} =
               read_key(exchange(restoring["assertion"]), restoring["key_manager"]["path"])

      # And the token is for that name alone: her new subject is not a name she has there.
      assert {:error, :forbidden} =
               read_data(exchange(again["assertion"]), slot_path(claims["oid"], "jira"))

      assert Identity.get_user(claims["oid"]).id == ada.id
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp requires_bao(%{skip: reason}), do: flunk("skipped: #{reason}")
  defp requires_bao(_context), do: :ok

  # Unique across runs, not only within one. The database forgets between runs and
  # OpenBao does not, and `System.unique_integer/1` starts again in every VM — small
  # numbers, stepping by the scheduler count — so a later run would draw an earlier run's
  # subject and find the slot that run wrote still there.
  defp unique, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp address, do: PersonAuth.address()
  defp root_token, do: Application.get_env(:troupe_plane, :transit, [])[:token]
  defp mount, do: "secret"
  defp reachable?, do: PersonAuth.reachable?()
  defp put(path, body), do: PersonAuth.put(path, body)

  # What a client does with an assertion: spend it at the key manager for a token.
  defp exchange(assertion) do
    assert {:ok, %{token: token}} = OpenBao.jwt_login(address(), @auth_path, @role, assertion)
    token
  end

  defp write_with(token, path, data) do
    case Req.request(
           method: :post,
           url: address() <> "/v1/#{mount()}/data/#{encode(path)}",
           headers: [{"x-vault-token", token}],
           json: %{"data" => data},
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      other -> {:error, other}
    end
  end

  defp read_key(token, path) do
    case Req.request(
           method: :get,
           url: address() <> "/v1/#{mount()}/data/#{encode(path)}",
           headers: [{"x-vault-token", token}],
           decode_body: true,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, get_in(body, ["data", "data", "key"])}
      {:ok, %{status: status}} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restore(key, nil), do: Application.delete_env(:troupe_plane, key)
  defp restore(key, value), do: Application.put_env(:troupe_plane, key, value)

  defp write_slot(subject, slot, value) do
    path = encode(slot_path(subject, slot))
    :ok = put("/v1/#{mount()}/data/#{path}", %{"data" => %{"value" => value}})
  end

  defp slot_path(subject, slot), do: "troupe/people/#{subject}/mcp/#{slot}"

  defp read_slot(token, subject, slot), do: read_data(token, slot_path(subject, slot))

  # A subject is a path segment and `idp|ada` is not a request target. One helper for the
  # write and the read, for the same reason `Troupe.KMS.OpenBao` has one.
  defp encode(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end

  defp read_data(token, path) do
    encoded = encode(path)

    case Req.request(
           method: :get,
           url: address() <> "/v1/#{mount()}/data/#{encoded}",
           headers: [{"x-vault-token", token}],
           decode_body: true,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, get_in(body, ["data", "data", "value"])}
      {:ok, %{status: 403}} -> {:error, :forbidden}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp token_for(policy) do
    name = "test-#{unique()}"
    :ok = put("/v1/sys/policies/acl/#{name}", %{"policy" => policy})

    {:ok, %{body: body}} =
      Req.request(
        method: :post,
        url: address() <> "/v1/auth/token/create",
        headers: [{"x-vault-token", root_token()}],
        json: %{"policies" => [name], "ttl" => "10m", "no_parent" => true},
        decode_body: true,
        retry: false
      )

    get_in(body, ["auth", "client_token"])
  end

  defp as(user), do: %{user: user, platform_admin?: false}

  # The claims, without verifying the signature: what is checked here is which subject the
  # plane put in, and OpenBao is what checks the rest.
  defp payload_of(jwt) do
    [_header, payload, _signature] = String.split(jwt, ".")
    padded = payload <> String.duplicate("=", rem(4 - rem(byte_size(payload), 4), 4))
    padded |> Base.url_decode64!() |> Jason.decode!()
  end
end
