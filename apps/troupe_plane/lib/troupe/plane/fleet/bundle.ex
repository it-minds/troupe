defmodule Troupe.Plane.Fleet.Bundle do
  @moduledoc """
  One published version of a config bundle.

  A bundle is a versioned set of agent definitions, skills, tool allowlists and MCP
  server *entries* — secret references only, never values. Versions are immutable once
  published: a running session records the version it started on and keeps it, so the
  only way a session's configuration changes under it is a deliberate upgrade at
  activation, recorded as a durable event.

  The hash is over the content and is what a worker checks after fetching. It exists
  because a bundle travels from the plane to a pod over a channel neither end fully
  controls, and applying a bundle that arrived wrong is worse than applying none.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Protocol.Bundle, as: Document

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "config_bundles" do
    field(:channel, :string)
    field(:version, :integer)
    field(:hash, :string)
    field(:content, :map, default: %{})
    # Counts and names, written at publish, so a list of versions does not decode the
    # documents behind it. Empty for a row an older plane wrote.
    field(:summary, :map, default: %{})
    field(:published_at, :utc_datetime_usec)
    field(:published_by, :string)
    field(:retired_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :channel,
    :version,
    :hash,
    :content,
    :summary,
    :published_at,
    :published_by,
    :retired_at
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(bundle, attrs) do
    bundle
    |> cast(attrs, @fields)
    |> validate_required([:channel, :version, :hash])
    |> unique_constraint([:channel, :version])
  end

  @doc """
  The hash of a bundle's content.

  Over the canonical JSON, so two plane replicas that built the same bundle from the
  same source agree on the hash without coordinating — and so a worker comparing what it
  fetched against what a heartbeat reported is comparing the same thing. The function
  itself lives in the protocol, where the worker's copy is the same code.
  """
  @spec hash(map()) :: String.t()
  defdelegate hash(content), to: Document

  @doc "Whether this version may still be started on."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{retired_at: nil}), do: true
  def live?(%__MODULE__{}), do: false
end
