defmodule Troupe.KMS.Policy do
  @moduledoc """
  Who may do what with session keys, written down once.

  Three credentials touch the key store and none of them can do what another can:

  * **a worker pod** may create and read keys, but only under the teams its profile is
    granted. A `ux` pod asking for a key of a team granted only to `dev` is refused by
    OpenBao, not by Troupe.
  * **the plane** may destroy key *metadata* — which is what erasure needs — and may not
    read a key at all. That is the Forbidden list's "no plane credential that can read
    session keys", and it is the reason a compromised plane cannot decrypt anything.
  * **the operator** touches keys not at all. It writes the roles; it is not in the
    path of a session.

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
  The policy for the plane: destroy metadata, read nothing.

  `delete` on the metadata path removes every version of a key, which is what makes an
  erasure final. There is deliberately no rule for the data path at all — not a deny,
  but an absence, because OpenBao denies by default and a deny rule invites somebody to
  "fix" it later by narrowing it.
  """
  @spec plane(String.t()) :: String.t()
  def plane(mount \\ "secret") do
    """
    path "#{mount}/metadata/troupe/teams/+/sessions/*" {
      capabilities = ["delete", "list", "read"]
    }
    """
  end

  @doc """
  The policy for signing session tokens: sign, and read the public key.

  Signing only. The key is created without `exportable`, so even this credential cannot
  take a copy of it — which is what makes a compromised plane able to mint tokens while
  it is compromised and forge nothing afterwards.
  """
  @spec signing(String.t(), String.t()) :: String.t()
  def signing(mount \\ "transit", key \\ "troupe-session-tokens") do
    """
    path "#{mount}/sign/#{key}" {
      capabilities = ["create", "update"]
    }

    path "#{mount}/keys/#{key}" {
      capabilities = ["read"]
    }
    """
  end

  @doc "The name a profile's policy is installed under."
  @spec worker_policy_name(String.t()) :: String.t()
  def worker_policy_name(profile), do: "troupe-worker-#{profile}"

  @doc "The name the plane's policy is installed under."
  @spec plane_policy_name() :: String.t()
  def plane_policy_name, do: "troupe-plane"
end
