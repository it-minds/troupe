defmodule Troupe.Worker.Session.Context do
  @moduledoc """
  What a worker needs to know to make one session durable.

  The data key is in here, which is the reason it is a struct passed between processes
  rather than something looked up: the key is held in memory for the life of an active
  session and never written to disk, so there has to be exactly one place it lives and
  a clear set of processes that hold it.

  The epoch comes from the plane and is carried unchanged. A worker never mints one —
  that is the whole of fencing.
  """

  alias Troupe.KMS
  alias Troupe.Worker.ObjectStore

  @enforce_keys [:session_id, :team, :epoch, :data_key, :store]
  defstruct [
    :session_id,
    :team,
    :epoch,
    :data_key,
    :store,
    :owner_subject,
    :profile,
    :state_dir,
    workspace: nil
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          team: String.t(),
          epoch: pos_integer(),
          data_key: binary(),
          store: Troupe.Worker.ObjectStore.t(),
          owner_subject: String.t() | nil,
          profile: String.t() | nil,
          state_dir: Path.t() | nil,
          workspace: Path.t() | nil
        }

  @doc """
  Build a context, creating the session's data key if it does not have one.

  Creating rather than fetching, because the call is idempotent: a session being
  activated again gets the key it already had, and one being created for the first time
  gets a new one. A worker that had to know which case it was in would get it wrong the
  first time a create was retried.
  """
  @spec open(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(session_id, opts) do
    team = Keyword.fetch!(opts, :team)
    kms = Keyword.get(opts, :kms, KMS.adapter())

    with {:ok, key} <- kms.create(team, session_id, Keyword.get(opts, :kms_options, [])) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         team: team,
         epoch: Keyword.get(opts, :epoch, 1),
         data_key: key,
         store: Keyword.get_lazy(opts, :store, &ObjectStore.from_env/0),
         owner_subject: Keyword.get(opts, :owner_subject),
         profile: Keyword.get(opts, :profile),
         state_dir: Keyword.get(opts, :state_dir),
         workspace: Keyword.get(opts, :workspace)
       }}
    end
  end

  @doc "Where this session's key lives, for the manifest."
  @spec key_path(t()) :: String.t()
  def key_path(%__MODULE__{} = context), do: KMS.path(context.team, context.session_id)
end
