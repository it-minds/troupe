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

  @doc "Create a session's data key. Idempotent: creating twice returns the same key."
  @callback create(team(), session_id(), keyword()) :: {:ok, key()} | {:error, term()}

  @doc "Read a session's data key. Refused where the credential is not scoped to the team."
  @callback fetch(team(), session_id(), keyword()) :: {:ok, key()} | {:error, term()}

  @doc "Destroy every version of a session's data key."
  @callback destroy(team(), session_id(), keyword()) :: :ok | {:error, term()}

  @doc "Whether a key exists, without reading it."
  @callback exists?(team(), session_id(), keyword()) :: boolean()

  @doc "The configured key manager."
  @spec adapter() :: module()
  def adapter, do: Application.get_env(:troupe_protocol, :kms, Troupe.KMS.OpenBao)

  @doc "The path a session's key lives at. One place, so nothing has to guess."
  @spec path(team(), session_id()) :: String.t()
  def path(team, session_id), do: "troupe/teams/#{team}/sessions/#{session_id}"

  @doc "A fresh 256-bit data key."
  @spec generate() :: key()
  def generate, do: :crypto.strong_rand_bytes(32)
end
