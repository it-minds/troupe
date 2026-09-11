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
  alias Troupe.KMS.OpenBao

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

  # -- helpers ----------------------------------------------------------------

  defp requires_bao(%{team: _} = context), do: context
  defp requires_bao(_), do: flunk("no OpenBao; see the message from setup_all")

  defp address, do: Application.get_env(:troupe_worker, :kms, [])[:address] || "http://localhost:58200"
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
