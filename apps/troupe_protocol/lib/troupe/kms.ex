defmodule Troupe.KMS do
  @moduledoc """
  Where a session's data key lives, and who may do what with it.

  A session's content is encrypted with a random 256-bit key that exists in exactly one
  place: the key manager. Workers fetch it to run a session and hold it in memory while
  they do; they never write it to disk. The plane can *destroy* a key and cannot read
  one, which is the property that makes erasure final — and the reason a compromised
  plane cannot decrypt session content even though it knows where all of it is.

  A behaviour rather than a module because OpenBao is a deployment choice. The
  guarantees are the contract:

  * `create/3` is idempotent per session and never returns an existing key's material to
    a caller that did not create it;
  * `destroy/2` removes **every version**, not the latest — a key that can be rolled
    back is a key that has not been destroyed;
  * reading a key needs a credential scoped to the session's team, so a `ux` pod cannot
    read a key belonging to a team granted only to `dev`.
  """

  @type session_id :: String.t()
  @type team :: String.t()
  @type key :: binary()

  @typedoc """
  Who a session's key belongs to: a team, or a person.

  A team session's key is under `teams/<team>/`, read by a pod with a credential scoped
  to that team. A private session's is under `people/<name>/`, read by that person's
  daemon with a credential the identity provider vouched for and no pod has. The two
  subtrees do not overlap and neither credential can reach the other, which is the
  property that makes "no worker profile is involved" true rather than intended.

  `<name>` is the person's name at the key manager, which the plane keeps and answers
  (Decision 755): their subject when they were first known, and unchanged when their
  subject changes, so nothing under it has to move.
  """
  @type owner :: team() | {:person, String.t()}

  @doc "Create a session's data key. Idempotent: creating twice returns the same key."
  @callback create(owner(), session_id(), keyword()) :: {:ok, key()} | {:error, term()}

  @doc "Read a session's data key. Refused where the credential is not scoped to the owner."
  @callback fetch(owner(), session_id(), keyword()) :: {:ok, key()} | {:error, term()}

  @doc "Destroy every version of a session's data key."
  @callback destroy(owner(), session_id(), keyword()) :: :ok | {:error, term()}

  @doc "Whether a key exists, without reading it."
  @callback exists?(owner(), session_id(), keyword()) :: boolean()

  @doc "The configured key manager."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:troupe_protocol, :kms, Troupe.KMS.OpenBao)

  @doc """
  The path a session's key lives at. One place, so nothing has to guess.

      iex> Troupe.KMS.path("engineering", "s-1")
      "troupe/teams/engineering/sessions/s-1"

      iex> Troupe.KMS.path({:person, "idp|ada"}, "s-2")
      "troupe/people/idp|ada/sessions/s-2"

  Two shapes and one function, because a path built in two places is a path that will
  one day be built two ways. The name is not escaped: OpenBao takes it as a path segment
  and a name containing a `/` would address somebody else's subtree, so
  `person_segment/1` refuses one rather than mangling it.
  """
  @spec path(owner(), session_id()) :: String.t()
  def path({:person, name}, session_id) do
    person_prefix(name) <> "/sessions/#{session_id}"
  end

  def path(team, session_id) when is_binary(team) do
    "troupe/teams/#{team}/sessions/#{session_id}"
  end

  @doc """
  Where a person's credential for one MCP server's slot lives.

  The second tenant under a person, beside their private sessions' data keys, and the
  reason the person policy covers the whole subtree rather than one prefix of it.

      iex> Troupe.KMS.slot_path("idp|ada", "jira")
      "troupe/people/idp|ada/mcp/jira"
  """
  @spec slot_path(String.t(), String.t()) :: String.t()
  def slot_path(name, slot), do: person_prefix(name) <> "/mcp/#{slot}"

  defp person_prefix(name), do: "troupe/people/#{person_segment(name)}"

  @doc """
  A person's name as one path segment, or a raise.

  The name is a subject from an identity provider, or the plane's own id for a person —
  `idp|ada`, `ada@example.test`, a UUID — opaque to us, and every shape we have seen is
  fine as a segment. One with a slash in it is not, and the failure of letting it through
  is that Ada's daemon writes under Bo's subtree. There is no sanitising here on purpose:
  a mangled name would silently be a *different* person, and two names that mangled the
  same way would share a key.
  """
  @spec person_segment(String.t()) :: String.t()
  def person_segment(name) when is_binary(name) do
    if String.contains?(name, "/") or name == "" do
      raise ArgumentError, "a person's name may not contain a slash or be empty: #{inspect(name)}"
    end

    name
  end

  @doc "A fresh 256-bit data key."
  @spec generate() :: key()
  def generate, do: :crypto.strong_rand_bytes(32)
end
