defmodule Troupe.KMS.OpenBaoTest do
  @moduledoc """
  Session keys, against a real OpenBao.

  The three properties that matter are all about *not* being able to do something, and
  none of them can be checked against a double: that creating twice does not replace a
  key and strand everything written under the old one, that destroying removes every
  version rather than the latest, and that a credential scoped to one team cannot read
  another team's keys.
  """

  use ExUnit.Case, async: false

  alias Troupe.KMS
  alias Troupe.KMS.{OpenBao, Policy}

  @moduletag timeout: 60_000

  setup_all do
    case reachable?() do
      true ->
        :ok

      false ->
        IO.puts(:stderr, """

        SKIPPED: no OpenBao (#{address()}).
        Bring one up with `scripts/dev-up`.
        """)

        {:ok, skip: true}
    end
  end

  setup context do
    if context[:skip] do
      :ok
    else
      team = "team-#{System.unique_integer([:positive])}"
      session = "s-#{System.unique_integer([:positive])}"
      on_exit(fn -> OpenBao.destroy(team, session, options()) end)
      %{team: team, session: session}
    end
  end

  test "a created key comes back, and is 256 bits", context do
    %{team: team, session: session} = requires_bao(context)

    assert {:ok, key} = OpenBao.create(team, session, options())
    assert byte_size(key) == 32

    assert {:ok, ^key} = OpenBao.fetch(team, session, options())
    assert OpenBao.exists?(team, session, options())
  end

  test "creating twice returns the same key, not a new one", context do
    %{team: team, session: session} = requires_bao(context)

    {:ok, first} = OpenBao.create(team, session, options())
    {:ok, second} = OpenBao.create(team, session, options())

    # Replacing it would strand every segment already written under the old key — the
    # session would still exist and none of it would decrypt.
    assert first == second
  end

  test "a key that was never created is not found", context do
    %{team: team, session: session} = requires_bao(context)

    assert {:error, :not_found} = OpenBao.fetch(team, session, options())
    refute OpenBao.exists?(team, session, options())
  end

  test "destroying removes every version, not the latest", context do
    %{team: team, session: session} = requires_bao(context)

    {:ok, _} = OpenBao.create(team, session, options())

    # A second version, as a rotation would leave behind.
    path = KMS.path(team, session)
    write_version(path, %{"key" => Base.encode64(:crypto.strong_rand_bytes(32))})

    assert :ok = OpenBao.destroy(team, session, options())

    assert {:error, :not_found} = OpenBao.fetch(team, session, options())
    # And nothing to roll back to: the metadata is gone, so no version remains.
    assert {:error, :not_found} = read_version(path, 1)
    assert {:error, :not_found} = read_version(path, 2)
  end

  test "destroying a key that was never there is not an error", context do
    %{team: team, session: session} = requires_bao(context)
    assert :ok = OpenBao.destroy(team, session, options())
  end

  test "keys are addressed by team, so a policy can be written per team" do
    assert KMS.path("dev", "s-1") == "troupe/teams/dev/sessions/s-1"
    assert KMS.path("ux", "s-1") == "troupe/teams/ux/sessions/s-1"
  end

  test "a person's keys are addressed by subject, under a subtree of their own" do
    assert KMS.path({:person, "idp|ada"}, "s-1") == "troupe/people/idp|ada/sessions/s-1"

    # Not sanitised, refused: a subject with a slash in it would address somebody else's
    # subtree, and a mangled subject would silently be a different person — or, worse,
    # two people who mangled the same way sharing a key.
    assert_raise ArgumentError, fn -> KMS.path({:person, "idp|a/b"}, "s-1") end
    assert_raise ArgumentError, fn -> KMS.path({:person, ""}, "s-1") end
  end

  test "a credential scoped to one team cannot read another team's keys", context do
    %{session: session} = requires_bao(context)

    {:ok, _} = OpenBao.create("dev", session, options())
    on_exit(fn -> OpenBao.destroy("dev", session, options()) end)

    # A token whose policy allows only `troupe/teams/ux/*`, which is what a ux pod's
    # Kubernetes-auth role gives it.
    scoped = scoped_token("ux")

    assert {:error, :forbidden} = OpenBao.fetch("dev", session, options(token: scoped))
    assert {:error, :not_found} = OpenBao.fetch("ux", session, options(token: scoped))
  end

  describe "what each credential may not do" do
    test "the plane cannot read any session key, of any team", context do
      %{session: session, team: team} = requires_bao(context)

      {:ok, key} = OpenBao.create(team, session, options())
      {:ok, _} = OpenBao.create("some-other-team", session, options())
      on_exit(fn -> OpenBao.destroy("some-other-team", session, options()) end)

      plane = token_for(Policy.plane(mount()))

      # The Forbidden list's "no plane credential that can read session keys", checked
      # against OpenBao rather than against this code's belief about it.
      assert {:error, :forbidden} = OpenBao.fetch(team, session, options(token: plane))
      assert {:error, :forbidden} = OpenBao.fetch("some-other-team", session, options(token: plane))

      # And it cannot write one either, which would be a way to replace a key with one
      # it knows.
      assert {:error, _} = OpenBao.create(team, "planted-#{session}", options(token: plane))

      # But it can destroy metadata, because erasure has to work — and once it has, the
      # key is gone for everyone including the pods that could read it.
      assert :ok = OpenBao.destroy(team, session, options(token: plane))
      assert {:error, :not_found} = OpenBao.fetch(team, session, options())
      assert byte_size(key) == 32
    end

    test "a profile's policy reaches only the teams that profile is granted", context do
      %{session: session} = requires_bao(context)

      {:ok, _} = OpenBao.create("granted-to-dev", session, options())
      {:ok, _} = OpenBao.create("granted-to-ux", session, options())

      on_exit(fn ->
        OpenBao.destroy("granted-to-dev", session, options())
        OpenBao.destroy("granted-to-ux", session, options())
      end)

      dev = token_for(Policy.worker(mount(), ["granted-to-dev"]))

      assert {:ok, _} = OpenBao.fetch("granted-to-dev", session, options(token: dev))
      assert {:error, :forbidden} = OpenBao.fetch("granted-to-ux", session, options(token: dev))
    end

    test "a pod cannot read a key under people/, and a person cannot read one under teams/",
         context do
      %{session: session, team: team} = requires_bao(context)
      ada = "idp|ada-#{System.unique_integer([:positive])}"
      bo = "idp|bo-#{System.unique_integer([:positive])}"

      {:ok, _} = OpenBao.create(team, session, options())
      {:ok, _} = OpenBao.create({:person, ada}, session, options())
      {:ok, _} = OpenBao.create({:person, bo}, session, options())

      on_exit(fn ->
        OpenBao.destroy(team, session, options())
        OpenBao.destroy({:person, ada}, session, options())
        OpenBao.destroy({:person, bo}, session, options())
      end)

      pod = token_for(Policy.worker(mount(), [team]))
      hers = token_for(Policy.person_for(mount(), ada))

      # A pod may read its own team's key and nothing under `people/` at all. No pod rule
      # mentions that subtree, and OpenBao denies by default, so this is an absence being
      # enforced rather than a deny somebody could narrow later.
      assert {:ok, _} = OpenBao.fetch(team, session, options(token: pod))
      assert {:error, :forbidden} = OpenBao.fetch({:person, ada}, session, options(token: pod))

      # A person may read their own and neither anybody else's nor any team's.
      assert {:ok, _} = OpenBao.fetch({:person, ada}, session, options(token: hers))
      assert {:error, :forbidden} = OpenBao.fetch({:person, bo}, session, options(token: hers))
      assert {:error, :forbidden} = OpenBao.fetch(team, session, options(token: hers))
    end

    test "the plane can destroy metadata under both subtrees, and read neither", context do
      %{session: session, team: team} = requires_bao(context)
      ada = "idp|ada-#{System.unique_integer([:positive])}"

      {:ok, _} = OpenBao.create(team, session, options())
      {:ok, _} = OpenBao.create({:person, ada}, session, options())

      plane = token_for(Policy.plane(mount()))

      assert {:error, :forbidden} = OpenBao.fetch(team, session, options(token: plane))
      assert {:error, :forbidden} = OpenBao.fetch({:person, ada}, session, options(token: plane))

      # Erasure is erasure: a private session gets the same finality a team's does, and a
      # plane that could erase one and not the other would have two answers to one
      # promise.
      assert :ok = OpenBao.destroy(team, session, options(token: plane))
      assert :ok = OpenBao.destroy({:person, ada}, session, options(token: plane))

      assert {:error, :not_found} = OpenBao.fetch(team, session, options())
      assert {:error, :not_found} = OpenBao.fetch({:person, ada}, session, options())
    end

    test "a pod cannot destroy a key, even one of its own team", context do
      %{session: session} = requires_bao(context)

      {:ok, _} = OpenBao.create("granted-to-dev", session, options())
      on_exit(fn -> OpenBao.destroy("granted-to-dev", session, options()) end)

      dev = token_for(Policy.worker(mount(), ["granted-to-dev"]))

      # Making a session unreadable is an erasure, and an erasure is a decision the plane
      # records and drives. A pod that could do it on its own would be a pod that could
      # destroy a session by being wrong.
      assert {:error, _} = OpenBao.destroy("granted-to-dev", session, options(token: dev))
      assert {:ok, _} = OpenBao.fetch("granted-to-dev", session, options())
    end
  end

  describe "signing as a profile's own identity (Decision 747)" do
    setup context do
      if context[:skip] do
        :ok
      else
        namespace = "troupe-w-test#{System.unique_integer([:positive])}"
        key = "#{namespace}.jira"
        {:ok, %{status: status}} = bao(:post, "/v1/transit/keys/#{key}", %{"type" => "rsa-2048"})
        true = status in 200..299

        on_exit(fn ->
          bao(:post, "/v1/transit/keys/#{key}/config", %{"deletion_allowed" => true})
          bao(:delete, "/v1/transit/keys/#{key}", nil)
        end)

        %{namespace: namespace, key: key}
      end
    end

    test "gives back a signature that verifies, RS256 and PS256, and never the key", context do
      %{key: key} = requires_bao(context)
      input = "header.payload"
      public = public_key(key, 1)

      assert {:ok, %{signature: rs256, key_version: 1}} =
               OpenBao.sign(key, input, [padding: :pkcs1v15], options())

      assert :public_key.verify(input, :sha256, rs256, public)

      assert {:ok, %{signature: ps256}} = OpenBao.sign(key, input, [padding: :pss], options())

      # A salt as long as the hash, which is what PS256 is: a verifier that holds to the
      # JWS definition would refuse transit's default, the longest salt that fits.
      assert :public_key.verify(input, :sha256, ps256, public, [
               {:rsa_padding, :rsa_pkcs1_pss_padding},
               {:rsa_pss_saltlen, 32}
             ])
    end

    test "signs with a pinned version after a rotation, and the latest otherwise", context do
      %{key: key} = requires_bao(context)
      {:ok, %{status: status}} = bao(:post, "/v1/transit/keys/#{key}/rotate", %{})
      assert status in 200..299

      assert {:ok, %{signature: old, key_version: 1}} =
               OpenBao.sign(key, "x", [key_version: 1], options())

      assert :public_key.verify("x", :sha256, old, public_key(key, 1))

      assert {:ok, %{signature: new, key_version: 2}} = OpenBao.sign(key, "x", [], options())
      assert :public_key.verify("x", :sha256, new, public_key(key, 2))
    end

    test "a key that is not there is :key_not_found", context do
      %{namespace: namespace} = requires_bao(context)
      assert {:error, :key_not_found} = OpenBao.sign("#{namespace}.gone", "x", [], options())
    end

    test "the policy lets a pod sign with its own namespace's keys and no other", context do
      %{namespace: namespace, key: key} = requires_bao(context)
      pod = token_for(Policy.mcp_identity_for("transit", namespace))

      assert {:ok, _} = OpenBao.sign(key, "x", [], options(token: pod))

      # Another profile's key, by a name that merely starts the same way, and the plane's
      # session-token key: a pod that could sign those could be somebody else.
      assert {:error, :forbidden} =
               OpenBao.sign("#{namespace}x.jira", "x", [], options(token: pod))

      assert {:error, :forbidden} =
               OpenBao.sign("troupe-session-tokens", "x", [], options(token: pod))
    end

    test "the policy is one template, on the namespace Kubernetes auth vouched for" do
      policy = Policy.mcp_identity("auth_kubernetes_1234")

      assert policy =~
               ~s(path "transit/sign/{{identity.entity.aliases.auth_kubernetes_1234.metadata.service_account_namespace}}.*")

      assert policy =~ ~s(capabilities = ["update"])
      refute policy =~ "read"
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp bao(method, path, body) do
    [
      method: method,
      url: address() <> path,
      headers: [{"x-vault-token", root_token()}],
      retry: false
    ]
    |> then(fn request -> if body, do: Keyword.put(request, :json, body), else: request end)
    |> Req.request()
  end

  defp public_key(key, version) do
    {:ok, %{status: 200, body: body}} = bao(:get, "/v1/transit/keys/#{key}", nil)

    [entry] =
      :public_key.pem_decode(get_in(body, ["data", "keys", to_string(version), "public_key"]))

    :public_key.pem_entry_decode(entry)
  end

  defp requires_bao(%{team: _} = context), do: context
  defp requires_bao(_), do: flunk("no OpenBao; see the message from setup_all")

  defp address, do: Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:28200"
  defp root_token, do: Application.get_env(:troupe_worker, :kms, [])[:token] || "troupe-dev-root"
  defp mount, do: Application.get_env(:troupe_worker, :kms, [])[:mount] || "secret"

  defp options(extra \\ []) do
    Keyword.merge([address: address(), token: root_token(), mount: mount()], extra)
  end

  defp reachable? do
    match?({:ok, %{status: 200}}, Req.request(method: :get, url: address() <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end

  defp write_version(path, data) do
    Req.request(
      method: :post,
      url: "#{address()}/v1/#{mount()}/data/#{path}",
      headers: [{"x-vault-token", root_token()}],
      json: %{"data" => data},
      retry: false
    )
  end

  defp read_version(path, version) do
    case Req.request(
           method: :get,
           url: "#{address()}/v1/#{mount()}/data/#{path}?version=#{version}",
           headers: [{"x-vault-token", root_token()}],
           decode_body: true,
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: _}} -> {:error, :not_found}
      error -> error
    end
  end

  # A real token carrying a real policy, so what is being tested is OpenBao's
  # enforcement rather than this test's imagination of it.
  defp token_for(document) do
    name = "troupe-test-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Req.request(
        method: :put,
        url: "#{address()}/v1/sys/policies/acl/#{name}",
        headers: [{"x-vault-token", root_token()}],
        json: %{"policy" => document},
        retry: false
      )

    {:ok, %{body: body}} =
      Req.request(
        method: :post,
        url: "#{address()}/v1/auth/token/create",
        headers: [{"x-vault-token", root_token()}],
        json: %{"policies" => [name], "ttl" => "10m"},
        decode_body: true,
        retry: false
      )

    get_in(body, ["auth", "client_token"])
  end

  # A real policy and a real token, because the question is whether OpenBao enforces the
  # path scoping — not whether this test can imagine that it does.
  defp scoped_token(team) do
    policy = "troupe-#{team}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Req.request(
        method: :put,
        url: "#{address()}/v1/sys/policies/acl/#{policy}",
        headers: [{"x-vault-token", root_token()}],
        json: %{
          "policy" => """
          path "#{mount()}/data/troupe/teams/#{team}/*" { capabilities = ["create", "read", "update"] }
          path "#{mount()}/metadata/troupe/teams/#{team}/*" { capabilities = ["delete", "list", "read"] }
          """
        },
        retry: false
      )

    {:ok, %{body: body}} =
      Req.request(
        method: :post,
        url: "#{address()}/v1/auth/token/create",
        headers: [{"x-vault-token", root_token()}],
        json: %{"policies" => [policy], "ttl" => "10m"},
        decode_body: true,
        retry: false
      )

    get_in(body, ["auth", "client_token"])
  end
end
