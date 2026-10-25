defmodule Troupe.Plane.KMSCheckTest do
  @moduledoc """
  What the plane's OpenBao role lacks, found look-only and said with the lines that grant
  it (#765).

  Against the development OpenBao, with tokens that carry some of the plane's policies and
  not others, as a role somebody set up by hand before a release added a grant does. The
  check asks `sys/capabilities-self` at each grant's paths and changes nothing: no key is
  made, signed with or read.
  """

  use Troupe.Plane.DataCase, async: false

  alias Troupe.KMS.Policy
  alias Troupe.Plane.{Admin, KMSCheck}
  alias Troupe.Plane.GitHub.App

  @moduletag timeout: 60_000

  @root %{subject: "root@example.test", role: :platform_admin, teams: []}
  @lead %{subject: "lead@example.test", role: :team_admin, teams: ["engineering"]}

  setup do
    unless bao_reachable?(), do: flunk("no OpenBao; bring it up with `scripts/dev-up`")
    %{transit: Application.get_env(:troupe_plane, :transit, [])}
  end

  test "a token that holds every grant is told so, grant by grant", context do
    {token, _names} = token_for(context.transit, Enum.map(Policy.plane_grants(), & &1.id))

    assert %{ok: true, error: nil, grants: grants} = KMSCheck.run(token: token)
    assert Enum.map(grants, & &1.id) == ~w(session-tokens plane-signing erasure invites github-app)
    assert Enum.all?(grants, & &1.ok)
    assert Enum.all?(grants, &is_nil(&1.fix))
  end

  # The live case: a role made before the plane signed its own answers carries the plane's
  # policy and the session-token one, and not the plane's signing key's.
  test "a missing grant is a sentence and the lines that add it, keeping the token's policies",
       context do
    ids = for grant <- Policy.plane_grants(), grant.id != "plane-signing", do: grant.id
    {token, held} = token_for(context.transit, ids)

    assert %{ok: false, grants: grants} = KMSCheck.run(token: token)
    missing = Enum.find(grants, &(&1.id == "plane-signing"))

    refute missing.ok
    assert missing.required
    assert missing.detail =~ "may not make, rotate and sign with the plane's own key"
    assert missing.detail =~ "refuses them"

    assert %{path: "transit/sign/troupe-plane-signing", capabilities: ["create", "update"]} in missing.missing

    assert missing.fix =~ "bao policy write troupe-plane-signing - <<'POLICY'"
    assert missing.fix =~ ~s(path "transit/keys/troupe-plane-signing/rotate")

    # The test's token is a static one, as the development plane's is, so the line makes
    # it again with what it carries and the policy added.
    for policy <- held, do: assert(missing.fix =~ "-policy=#{policy}")
    assert missing.fix =~ "-policy=troupe-plane-signing"

    # And nothing else is reported missing.
    assert Enum.all?(grants -- [missing], & &1.ok)
  end

  test "the GitHub App's grant missing leaves the plane healthy, and says what it is for",
       context do
    required = for grant <- Policy.plane_grants(), grant.required, do: grant.id
    {token, _names} = token_for(context.transit, required)

    assert %{ok: true, grants: grants} = KMSCheck.run(token: token)
    github = Enum.find(grants, &(&1.id == "github-app"))
    refute github.ok
    assert github.detail =~ "(needed only for that)"
    refute github.required
  end

  test "once a GitHub App is set up, its grant is required and missing it is not healthy",
       context do
    Repo.insert!(%App{
      id: App.id(),
      app_id: 4242,
      key_version: 1,
      installations: [%{"owner" => "example", "id" => 7}]
    })

    required = for grant <- Policy.plane_grants(), grant.required, do: grant.id
    {token, _names} = token_for(context.transit, required)

    assert %{ok: false, grants: grants} = KMSCheck.run(token: token)
    github = Enum.find(grants, &(&1.id == "github-app"))
    refute github.ok
    assert github.required
    refute github.detail =~ "(needed only for that)"
    assert github.detail =~ "one set up before stops signing"
  end

  test "an OpenBao that does not answer is one sentence, and nothing is listed" do
    assert %{ok: false, grants: [], error: error} =
             KMSCheck.run(address: "http://127.0.0.1:9", receive_timeout: 500)

    assert error =~ "OpenBao did not answer the plane's check"
  end

  test "a token with no policy at all is told what each grant is for", context do
    {token, []} = token_for(context.transit, [])

    assert %{ok: false, grants: grants} = KMSCheck.run(token: token)
    assert Enum.all?(grants, &(not &1.ok))
    assert Enum.all?(grants, &(&1.fix =~ "bao policy write #{&1.policy}"))
  end

  describe "admin.overview" do
    test "a platform admin's says what the plane's OpenBao role may do" do
      assert {:ok, %{openbao: %{grants: [_ | _]} = openbao}} = Admin.overview(@root)
      assert is_boolean(openbao.ok)
    end

    test "a team admin's says nothing about the key manager" do
      _engineering = team_with_grant("engineering", "dev", name: "engineering")
      assert {:ok, overview} = Admin.overview(@lead)
      refute Map.has_key?(overview, :openbao)
    end
  end

  # A token carrying the policies of these grants and the default one, which is what a
  # role's login gives, and the names they were written under: the code's text, under a
  # name of this run's, since the development OpenBao is shared and is not rolled back.
  defp token_for(transit, ids) do
    run = System.unique_integer([:positive])

    names =
      for grant <- Policy.plane_grants(), grant.id in ids do
        name = "#{grant.policy}-check-#{run}"

        {:ok, _} =
          bao_post(transit, "/v1/sys/policies/acl/#{name}", %{
            "policy" => Policy.grant_policy(grant)
          })

        name
      end

    {:ok, %{"auth" => %{"client_token" => token}}} =
      bao_post(transit, "/v1/auth/token/create", %{
        "policies" => ["default" | names],
        "ttl" => "5m"
      })

    {token, names}
  end

  defp bao_post(transit, path, body) do
    case Req.post(transit[:address] <> path,
           headers: [{"x-vault-token", transit[:token]}],
           json: body,
           retry: false
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {status, body}}
    end
  end

  defp bao_reachable? do
    address = Application.get_env(:troupe_plane, :transit, [])[:address]

    is_binary(address) and
      match?({:ok, %{status: 200}}, Req.request(url: address <> "/v1/sys/health", retry: false))
  rescue
    _ -> false
  end
end
