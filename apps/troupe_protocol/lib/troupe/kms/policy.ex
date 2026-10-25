defmodule Troupe.KMS.Policy do
  @moduledoc """
  Who may do what with session keys, written down once.

  Three credentials touch the key store and none of them can do what another can:

  * **a worker pod** may create and read keys, but only under the teams its profile is
    granted. A `ux` pod asking for a key of a team granted only to `dev` is refused by
    OpenBao, not by Troupe. No pod rule mentions `people/` at all.
  * **a person's daemon** may create and read keys under its own name, and no other's.
    The policy is templated on the name the plane vouched for, which is the person's name
    at the key manager (Decision 755), so there is one policy for everybody and no rule
    anybody has to write per person.
  * **the plane** may destroy key *metadata* — which is what erasure needs — and may not
    read a key at all. That is the Forbidden list's "no plane credential that can read
    session keys", and it is the reason a compromised plane cannot decrypt anything.
  * **the operator** touches keys not at all. It writes the roles; it is not in the
    path of a session.

  A pod also signs, with the transit key of its profile's identity at an MCP server
  (`mcp_identity/2`), and with no other.

  Rendered here rather than written into a chart by hand so that the policy the tests
  prove and the policy a cluster installs are the same string.
  """

  @doc """
  The policy for a profile's pods: create and read, under its granted teams only.

  `create` and `update` on the data path, because a session key is written once and a
  retry must be able to write it again; `read` on both paths, because KV v2 needs the
  metadata path to answer whether a key exists. No `delete` anywhere: a pod must not be
  able to make a session unreadable, even its own.
  """
  @spec worker(String.t(), [String.t()]) :: String.t()
  def worker(mount \\ "secret", teams) do
    teams
    |> Enum.sort()
    |> Enum.map_join("\n", fn team ->
      """
      path "#{mount}/data/troupe/teams/#{team}/sessions/*" {
        capabilities = ["create", "read", "update"]
      }

      path "#{mount}/metadata/troupe/teams/#{team}/sessions/*" {
        capabilities = ["read", "list"]
      }
      """
    end)
  end

  @doc """
  The policy for a person's daemon: create and read, under their own name only.

  Templated rather than per-person: `identity.entity.aliases.<accessor>.name` is the
  `sub` OpenBao itself put on the entity when it verified the plane's assertion, and the
  plane writes the person's name at the key manager there (Decision 755), so a daemon
  cannot name somebody else's subtree by asking. That name is their subject unless they
  have been moved to another claim since they were first known, and is what keeps a
  moved person's subtree theirs. One policy, attached to one JWT role, and adding a
  person is the identity provider's business rather than an operator's.

  The whole subtree under the person, not one prefix of it. There are two tenants there
  already — `sessions/` for a private session's data key, `mcp/` for a credential they
  connected — and a policy written per prefix is a policy somebody has to remember to
  widen. Everything under a person belongs to that person; that is the whole statement,
  and it is the one worth writing down.

  Read and write, no `delete`, exactly as a pod has: a person must not be able to make
  their own session unreadable outside erasure, for the same reason a pod must not.

  And one rule for invitations into a private session (`Troupe.KMS.invited_slot/4`):
  `create`, and nothing else, under every person's `invited/`, which is how the owner's
  daemon hands the session's key to the person invited, into that person's own subtree. It
  can put a key there and cannot read one back or overwrite one, its own included; the
  invitee reads it under the rule above, which OpenBao prefers for their own subtree,
  since its first wildcard comes later. Putting something in somebody's slot is giving
  them something, never reading what is theirs.
  """
  @spec person(String.t(), String.t()) :: String.t()
  def person(mount \\ "secret", accessor) do
    person_for(mount, "{{identity.entity.aliases.#{accessor}.name}}")
  end

  @doc """
  The same policy with a name already in it, rather than a template.

  This is what OpenBao evaluates `person/2` to once it has verified a token and resolved
  the entity — the template decides *which* name lands here and changes nothing about
  the capabilities. Exposed because a test that wants to prove what a person's credential
  may and may not reach can then issue a token with this policy directly, instead of
  standing up a JWT auth mount and an identity provider to arrive at the same string.
  """
  @spec person_for(String.t(), String.t()) :: String.t()
  def person_for(mount, name) do
    """
    path "#{mount}/data/troupe/people/#{name}/*" {
      capabilities = ["create", "read", "update"]
    }

    path "#{mount}/metadata/troupe/people/#{name}/*" {
      capabilities = ["read", "list"]
    }

    path "#{mount}/data/troupe/people/+/invited/*" {
      capabilities = ["create"]
    }
    """
  end

  @doc """
  The policy for the plane: destroy metadata, read nothing.

  `delete` on the metadata path removes every version of a key, which is what makes an
  erasure final. There is deliberately no rule for the data path at all — not a deny,
  but an absence, because OpenBao denies by default and a deny rule invites somebody to
  "fix" it later by narrowing it.

  Both subtrees, because erasure is erasure: a person asking for their private session to
  be destroyed gets the same finality a team's session gets, and a plane that could erase
  one and not the other would have two answers to one promise.

  One widening, and the smallest that answers the question. A person's connections carry
  `list` and `read` on **metadata only**, which in KV v2 is versions and timestamps and
  never a value — so a panel can say "Ada has connected Jira" and can say nothing more.
  No `delete`: removing a credential is the person's, and an admin who could do it is an
  admin who has a reason to want to.
  """
  @spec plane(String.t()) :: String.t()
  def plane(mount \\ "secret"), do: render(plane_rules(mount))

  defp plane_rules(mount) do
    [
      {"#{mount}/metadata/troupe/teams/+/sessions/*", ["delete", "list", "read"]},
      {"#{mount}/metadata/troupe/people/+/sessions/*", ["delete", "list", "read"]},
      {"#{mount}/metadata/troupe/people/+/mcp/*", ["list", "read"]}
    ]
  end

  @doc """
  The policy for signing session tokens: sign, and read the public key.

  Signing only. The key is created without `exportable`, so even this credential cannot
  take a copy of it — which is what makes a compromised plane able to mint tokens while
  it is compromised and forge nothing afterwards.
  """
  @spec signing(String.t(), String.t()) :: String.t()
  def signing(mount \\ "transit", key \\ "troupe-session-tokens"),
    do: render(signing_rules(mount, key))

  defp signing_rules(mount, key) do
    [
      {"#{mount}/sign/#{key}", ["create", "update"]},
      {"#{mount}/keys/#{key}", ["read"]}
    ]
  end

  @doc """
  The policy for the plane's own signing key (#657), which signs what it tells people's
  machines: create it on first use, read its public half, rotate it and sign with it.

  `create` and `update` on the key's path are the create; transit makes a key there with
  the type the plane sends, `ed25519`, not exportable. There is no `export`, `backup` or
  `config` path, so not even the plane can take a copy of it or make it exportable later.
  """
  @spec plane_signing(String.t(), String.t()) :: String.t()
  def plane_signing(mount \\ "transit", key \\ "troupe-plane-signing"),
    do: render(plane_signing_rules(mount, key))

  defp plane_signing_rules(mount, key) do
    [
      {"#{mount}/keys/#{key}", ["create", "read", "update"]},
      {"#{mount}/keys/#{key}/rotate", ["update"]},
      {"#{mount}/sign/#{key}", ["create", "update"]}
    ]
  end

  @doc """
  The policy for the plane's GitHub App key: import it, add a version, sign with it, and
  read its public half; nothing that exports it.

  The plane is handed the App's private key once and imports it, wrapped for transit's
  bring-your-own-key import, so it reads the wrapping key and writes `import` and
  `import_version` on this key alone. The key is created without `exportable`, and this
  policy has no `export` path either, so not even the plane can take the key back out.

  The App's webhook secret is the same, as an HMAC key (`webhook_key`): imported, given a
  version, and asked for the HMAC of each delivery's body, which the plane compares with
  the signature GitHub sent; never exported.

  Both are deleted when the App is removed (`admin.github.delete`), which transit allows
  once a key's `config` says so: `update` on each `config` and `delete` on each key.
  """
  @spec github_app(String.t(), String.t(), String.t()) :: String.t()
  def github_app(
        mount \\ "transit",
        key \\ "troupe-github-app",
        webhook_key \\ "troupe-github-webhook"
      ),
      do: render(github_app_rules(mount, key, webhook_key))

  defp github_app_rules(mount, key, webhook_key) do
    [
      {"#{mount}/wrapping_key", ["read"]},
      {"#{mount}/keys/#{key}", ["read", "delete"]},
      {"#{mount}/keys/#{key}/config", ["update"]},
      {"#{mount}/keys/#{key}/import", ["create", "update"]},
      {"#{mount}/keys/#{key}/import_version", ["create", "update"]},
      {"#{mount}/sign/#{key}", ["create", "update"]},
      {"#{mount}/keys/#{webhook_key}", ["read", "delete"]},
      {"#{mount}/keys/#{webhook_key}/config", ["update"]},
      {"#{mount}/keys/#{webhook_key}/import", ["create", "update"]},
      {"#{mount}/keys/#{webhook_key}/import_version", ["create", "update"]},
      {"#{mount}/hmac/#{webhook_key}/sha2-256", ["create", "update"]}
    ]
  end

  @doc """
  The policy for a profile's own identity at its MCP servers (Decision 747): sign with a
  transit key named after the pod's own namespace, `<namespace>.<anything>`, and nothing
  else.

  Templated on the namespace Kubernetes auth vouched for, as `person/2` is on the name:
  one policy, on the one role every pod logs in with, and a pod in `troupe-w-ux` cannot
  sign with `troupe-w-dev.jira` however it asks, because the name its policy evaluates to
  is its own. `accessor` is the Kubernetes auth mount's.

  Sign only. No `read` on the key, which a pod has no use for, and no reach to the plane's
  session-token key, whose name has no dot in it: a pod that could sign session tokens
  could open any session on any pod.
  """
  @spec mcp_identity(String.t(), String.t()) :: String.t()
  def mcp_identity(mount \\ "transit", accessor) do
    mcp_identity_for(
      mount,
      "{{identity.entity.aliases.#{accessor}.metadata.service_account_namespace}}"
    )
  end

  @doc """
  The same policy with a namespace already in it, as OpenBao evaluates `mcp_identity/2`
  for a pod of that namespace; a test issues a token with this one, as `person_for/2`
  is used.
  """
  @spec mcp_identity_for(String.t(), String.t()) :: String.t()
  def mcp_identity_for(mount, namespace) do
    """
    path "#{mount}/sign/#{namespace}.*" {
      capabilities = ["update"]
    }
    """
  end

  @doc "The name the MCP identity policy is installed under."
  @spec mcp_identity_policy_name() :: String.t()
  def mcp_identity_policy_name, do: "troupe-worker-mcp-identity"

  @doc "The name a profile's policy is installed under."
  @spec worker_policy_name(String.t()) :: String.t()
  def worker_policy_name(profile), do: "troupe-worker-#{profile}"

  @doc """
  The Kubernetes-auth role a profile's pods log in under, where an installation makes one
  per profile (Decision 753): named as its policy is, and carrying it. Otherwise every pod
  logs in as `troupe-worker`.
  """
  @spec worker_role_name(String.t()) :: String.t()
  def worker_role_name(profile), do: worker_policy_name(profile)

  @doc "The name the plane's policy is installed under."
  @spec plane_policy_name() :: String.t()
  def plane_policy_name, do: "troupe-plane"

  # -- what the plane's own credential must be granted ---------------------------------

  @typedoc """
  One thing the plane does with its OpenBao credential: what it is for, what fails
  without it, the policy it is installed as, and that policy's rules. `required: false`
  is one only some deployments need, the GitHub App's.
  """
  @type grant :: %{
          optional(:only) => String.t(),
          id: String.t(),
          policy: String.t(),
          required: boolean(),
          for: String.t(),
          without: String.t(),
          rules: [{String.t(), [String.t()]}]
        }

  @doc """
  Everything the plane's own credential must be allowed, one grant per thing it does.

  The one list of them. The plane checks each against its own token, look-only, when it
  starts and on the console's Overview, and prints the policy of one it lacks with the
  lines that grant it; `mix troupe.openbao.policy` writes `docs/admin/openbao.md` from the
  same entries. The plane cannot grant itself any of them: writing a policy takes an
  OpenBao administrator, which the plane never is.

  The mounts and key names are the deployment's: `:kv_mount`, `:transit_mount`,
  `:session_key`, `:signing_key`, `:github_key` and `:github_webhook_key`, each with the
  default the plane has.
  """
  @spec plane_grants(keyword()) :: [grant()]
  def plane_grants(opts \\ []) do
    kv = Keyword.get(opts, :kv_mount, "secret")
    transit = Keyword.get(opts, :transit_mount, "transit")

    [
      %{
        id: "session-tokens",
        policy: "troupe-plane-session-tokens",
        required: true,
        for: "sign session tokens, and read the key's public half that workers check them with",
        without: "no session opens, and no pod or person's daemon can check a token",
        rules: signing_rules(transit, Keyword.get(opts, :session_key, "troupe-session-tokens"))
      },
      %{
        id: "plane-signing",
        policy: "troupe-plane-signing",
        required: true,
        for:
          "make, rotate and sign with the plane's own key, which signs what it tells people's machines",
        without:
          "the client versions and defaults go out unsigned, and every client that pinned this plane's key refuses them",
        rules:
          plane_signing_rules(transit, Keyword.get(opts, :signing_key, "troupe-plane-signing"))
      },
      %{
        id: "erasure",
        policy: plane_policy_name(),
        required: true,
        for:
          "destroy an erased session's key, a team's or a person's, and see which credentials a person has connected",
        without:
          "erasing a session cannot destroy its key, and the console cannot say who has connected what",
        rules: plane_rules(kv)
      },
      %{
        id: "invites",
        policy: "troupe-plane-invites",
        required: false,
        only: "only for inviting people into private sessions",
        for:
          "destroy the copy of a private session's key its owner's daemon put in an invitee's own slot, when the invitation is taken back or the session erased",
        without:
          "an erasure of a private session somebody was invited into stays pending, and taking an invitation back leaves the copy it gave in the invitee's slot",
        rules: invites_rules(kv)
      },
      %{
        id: "github-app",
        policy: "troupe-plane-github",
        required: false,
        only: "only with a GitHub App",
        for: "import, sign with and delete the GitHub App's key and webhook secret",
        without: "a GitHub App cannot be set up, and one set up before stops signing",
        rules:
          github_app_rules(
            transit,
            Keyword.get(opts, :github_key, "troupe-github-app"),
            Keyword.get(opts, :github_webhook_key, "troupe-github-webhook")
          )
      }
    ]
  end

  @doc """
  The policy for invitations into a private session: destroy the copies of its key in
  invitees' slots, on the metadata path, and nothing on the data path. The plane holds the
  path of each copy, and can end one and read none, as it can a session's own key.
  """
  @spec invites(String.t()) :: String.t()
  def invites(mount \\ "secret"), do: render(invites_rules(mount))

  defp invites_rules(mount), do: [{"#{mount}/metadata/troupe/people/+/invited/*", ["delete"]}]

  @doc "A grant's rules as the policy text `bao policy write` takes."
  @spec grant_policy(grant()) :: String.t()
  def grant_policy(%{rules: rules}), do: render(rules)

  @doc """
  A path a look-only check can ask about for each rule: the rule's own, with every `+`
  and a trailing `*` filled in, since OpenBao answers what a token may do at a path and
  not at a pattern.
  """
  @spec probe_path(String.t()) :: String.t()
  def probe_path(pattern) do
    pattern
    |> String.split("/")
    |> Enum.map_join("/", fn
      "+" -> "troupe-check"
      "*" -> "troupe-check"
      segment -> String.replace(segment, ~r/\*$/, "troupe-check")
    end)
  end

  @doc """
  The lines an OpenBao administrator runs to give the plane a grant: write its policy,
  then add it to what the plane's login carries. `policies` is what the plane's token
  carries now, so the role keeps them. With `role: nil` the plane uses a static token
  (`bao.tokenSecretName`), and the line says to make it a new one.
  """
  @spec grant_lines(grant(), keyword()) :: String.t()
  def grant_lines(grant, opts \\ []) do
    policies =
      opts
      |> Keyword.get(:policies, [])
      |> Enum.reject(&(&1 in ["default", "root"]))
      |> Kernel.++([grant.policy])
      |> Enum.uniq()
      |> Enum.join(",")

    attach =
      case Keyword.get(opts, :role) do
        nil ->
          "bao token create -policy=#{String.replace(policies, ",", " -policy=")}   # the plane's new static token"

        role ->
          "bao write auth/#{Keyword.get(opts, :auth_path, "kubernetes")}/role/#{role} token_policies=#{policies}"
      end

    """
    bao policy write #{grant.policy} - <<'POLICY'
    #{String.trim_trailing(grant_policy(grant))}
    POLICY
    #{attach}
    """
  end

  @doc """
  The line that makes the plane's Kubernetes-auth role, carrying the policies of every
  required grant (or `:policies`): the plane's ServiceAccount in its namespace, for the
  audience its projected token carries. Options `:auth_path`, `:role`, `:namespace`,
  `:audience`, and the names `plane_grants/1` takes.
  """
  @spec plane_role_line(keyword()) :: String.t()
  def plane_role_line(opts \\ []) do
    policies =
      Keyword.get_lazy(opts, :policies, fn ->
        for grant <- plane_grants(opts), grant.required, do: grant.policy
      end)

    "bao write auth/#{Keyword.get(opts, :auth_path, "kubernetes")}/role/" <>
      "#{Keyword.get(opts, :role, "troupe-plane")} bound_service_account_names=troupe-plane " <>
      "bound_service_account_namespaces=#{Keyword.get(opts, :namespace, "troupe-system")} " <>
      "audience=#{Keyword.get(opts, :audience, "troupe-kms")} " <>
      "token_policies=#{Enum.join(policies, ",")} ttl=1h"
  end

  # The text of one policy: a `path` block per rule, a blank line between them.
  defp render(rules) do
    Enum.map_join(rules, "\n", fn {path, capabilities} ->
      """
      path "#{path}" {
        capabilities = [#{Enum.map_join(capabilities, ", ", &~s("#{&1}"))}]
      }
      """
    end)
  end

  @doc "The name the person policy is installed under, and the JWT role that carries it."
  @spec person_policy_name() :: String.t()
  def person_policy_name, do: "troupe-person"

  @doc """
  The JWT auth role a person's assertion is exchanged through.

  Rendered here for the same reason the policies are: what the tests prove and what a
  cluster installs should be one string rather than two that drift.

  Every field is a narrowing. `bound_audiences` and `bound_issuer` say the assertion has
  to be one the plane minted for the key manager — a session token, whose audience is a
  pod, is refused here. `user_claim: "sub"` is what makes the alias name the person, by
  the name the plane keeps for them there (Decision 755), and the alias name is what the
  policy templates on, so a caller cannot name somebody else's subtree by asking.
  """
  @spec person_role(String.t(), String.t()) :: map()
  def person_role(issuer, audience) do
    %{
      "role_type" => "jwt",
      "user_claim" => "sub",
      "bound_audiences" => [audience],
      "bound_issuer" => issuer,
      "token_policies" => [person_policy_name()],
      "token_ttl" => "20m",
      "token_max_ttl" => "1h",
      # No renewal and no periodic token: a session that outlives an hour exchanges a
      # fresh assertion, which is a round trip the plane is on the path of anyway.
      "token_type" => "service"
    }
  end

  @doc """
  The JWT auth mount's own configuration: which keys a signature is checked against.

  The transit key's public half, in PEM, every version of it — a token minted moments
  before a rotation is signed by the old one and stays good until it expires, which is
  the same reason `Tokens.jwks/1` answers with every version.

  Separate from the role because OpenBao keeps them apart: the mount decides what a valid
  signature is, the role decides what a valid *claim set* is, and a mount with no keys
  answers every login with "could not load configuration" rather than a refusal anybody
  could read.
  """
  @spec person_auth_config([String.t()]) :: map()
  def person_auth_config(public_keys) do
    %{"jwt_validation_pubkeys" => public_keys, "default_role" => person_policy_name()}
  end
end
