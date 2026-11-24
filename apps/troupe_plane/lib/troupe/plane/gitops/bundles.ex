defmodule Troupe.Plane.Gitops.Bundles do
  @moduledoc """
  `ConfigBundle` resources, each a channel's bundle as a repository holds it, published by
  the pass as the channel's versions.

  ## One resource per channel, its spec the document

  `metadata.name` is the channel and `spec` is the bundle document exactly as
  `admin.bundle.publish` takes it, in the document's own snake_case and with nothing
  translated or filled in. So the hash of the spec is the hash of the version it becomes,
  and anyone holding the repository's file can say which version on the plane is that
  file: `admin.bundle.validate` answers the hash of a document without publishing it. A
  channel that is not a Kubernetes name cannot be held, and one the plane composes for a
  profile (`profile:<name>`) is never a resource's.

  ## What a pass does with one

  The resource is checked as a person's publish is (`Troupe.Plane.Bundles.check/1` and the
  reach of its MCP servers), and refused above 1 MiB of JSON: a Kubernetes object stops a
  little above that, and a bundle published by hand may be 4 MiB. One that passes is handed
  to `Troupe.Plane.Bundles.follow/3`, which publishes it only when its hash differs from
  what this resource last published, adopts the current version where that is already the
  content, and reports a version an administrator retired since rather than publishing it
  again. A refused one publishes nothing and the channel keeps its current version.

  A resource whose generation is the one the hold last read, with nothing reported about
  it, is not checked again: the content is the version the hold names. One that was refused
  is read whole every pass, so a policy that changes can let it through.

  ## When the resource goes

  The channel is released and nothing else: no version is retired, the current one stays,
  and a session pinned to any of them notices nothing. From then on it is published by hand.
  """

  @behaviour Troupe.Plane.Gitops

  alias Troupe.Plane.{Audit, Bundles, Gitops, Reach}
  alias Troupe.Plane.Bundles.Effective
  alias Troupe.Plane.Fleet.BundleHold

  require Logger

  @kind "ConfigBundle"

  # Not a person: a commit somebody reviewed and an applier applied.
  @actor "system:gitops"

  # What a repository's bundle may be, as JSON: under the 1.5 MiB a Kubernetes object may
  # be with room for its metadata, and the size of a ConfigMap or a Secret, which an
  # operator already knows.
  @max_bytes 1_048_576

  # The revision a pipeline or kustomize may write on the resource. Shown beside the
  # version and never trusted: anybody who can apply the resource can write it. The hash is
  # the proof.
  @revision "troupe.dev/revision"

  @impl Gitops
  def kind, do: @kind

  @impl Gitops
  def api_version, do: "troupe.dev/v1alpha1"

  @doc "The most a `ConfigBundle`'s spec may be, in bytes of JSON."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @impl Gitops
  def rows, do: Bundles.holds()

  @impl Gitops
  def context do
    %{holds: Bundles.holds(), reported: MapSet.new(Gitops.reports(@kind), & &1.name)}
  end

  # -- reading one --------------------------------------------------------------

  @impl Gitops
  def read(resource, context) do
    channel = get_in(resource, ["metadata", "name"])
    spec = resource["spec"] || %{}

    meta = %{
      resource_generation: get_in(resource, ["metadata", "generation"]),
      source_revision: revision(resource)
    }

    attrs = Map.put(meta, :content, spec)

    with :ok <- usable(channel),
         :ok <- sized(spec),
         :ok <- schema(spec) do
      if read_before?(channel, meta, context), do: {:ok, attrs}, else: checked(channel, attrs)
    end
  end

  defp revision(resource) do
    case get_in(resource, ["metadata", "annotations", @revision]) do
      revision when is_binary(revision) and revision != "" -> revision
      _none -> nil
    end
  end

  defp usable(channel) do
    if Effective.reserved?(channel),
      do:
        {:error,
         [
           "metadata.name #{channel} is the bundle the plane composes for a profile from the " <>
             "channels of the profiles it extends; hold those channels instead"
         ]},
      else: :ok
  end

  defp sized(spec) do
    case byte_size(Jason.encode!(spec)) do
      size when size > @max_bytes ->
        {:error,
         [
           "the resource is #{size} bytes of JSON, the limit is 1 MiB (#{@max_bytes}; a " <>
             "bundle published by hand may be 4 MiB): move a large skill file out, or publish " <>
             "this channel by hand"
         ]}

      _fits ->
        :ok
    end
  end

  # The CRD requires a schema, which a resource stored without one (or by an older CRD)
  # need not have; schema 0 is a document no plane writes any more.
  defp schema(%{"schema" => 1}), do: :ok

  defp schema(spec),
    do:
      {:error,
       [
         "spec.schema is #{inspect(spec["schema"])}, and a repository's bundle is a schema 1 " <>
           "document: say schema: 1"
       ]}

  defp read_before?(channel, meta, context) do
    case Map.get(context.holds, channel) do
      %BundleHold{resource_generation: generation} when is_integer(generation) ->
        generation == meta.resource_generation and not MapSet.member?(context.reported, channel)

      _none ->
        false
    end
  end

  # What a person's publish is checked by, asked without writing anything. Each refusal is
  # already a sentence, the reach's too.
  defp checked(channel, attrs) do
    with {:ok, parsed} <- Bundles.check(attrs.content),
         :ok <- Reach.bundle(channel, parsed) do
      {:ok, attrs}
    else
      {:error, {:invalid_bundle, messages}} -> {:error, messages}
    end
  end

  # -- writing one --------------------------------------------------------------

  @impl Gitops
  def take(channel, attrs, hold, _resource) do
    meta = Map.take(attrs, [:resource_generation, :source_revision])

    case Bundles.follow(channel, attrs.content, meta) do
      {:ok, {:unchanged, _hold}} ->
        {:unchanged, nil}

      {:ok, {:retired, hold, current}} ->
        {:unchanged, {"retired", [retired(hold, current)]}}

      {:ok, {:adopted, bundle}} ->
        record("bundle.hold", channel, bundle, meta)

        Logger.info(
          "troupe plane: gitops: channel #{channel} is held by its ConfigBundle, at the " <>
            "current v#{bundle.version}, which is already its content"
        )

        {:created, nil}

      {:ok, {:published, bundle}} ->
        record("bundle.publish", channel, bundle, meta)

        Logger.info(
          "troupe plane: gitops: channel #{channel} published as v#{bundle.version} from " <>
            "its ConfigBundle at generation #{meta.resource_generation}"
        )

        {if(is_nil(hold), do: :created, else: :changed), nil}

      # Checked a moment ago and refused now: the policy changed in between.
      {:error, {:invalid_bundle, messages}} ->
        {:unchanged, {"refused", messages}}

      # The pass reports a raise as this resource's refusal, with the rest going on.
      {:error, reason} ->
        raise "publishing it failed: #{inspect(reason)}"
    end
  end

  defp retired(hold, current) do
    now =
      case current do
        nil -> "new sessions get nothing on it"
        bundle -> "new sessions get v#{bundle.version}"
      end

    "v#{hold.version}, the repository's content, is retired: #{now}; commit a change to " <>
      "publish again"
  end

  # The admin path's detail, and which resource said so.
  defp record(action, channel, bundle, meta) do
    {:ok, _} =
      Audit.record(@actor, action, channel, %{
        "version" => bundle.version,
        "hash" => bundle.hash,
        "summary" => bundle.summary,
        "resource" => channel,
        "generation" => meta.resource_generation,
        "revision" => meta.source_revision
      })
  end

  # -- a hold with no resource ----------------------------------------------------

  @impl Gitops
  def gone(%BundleHold{} = hold) do
    :ok = Bundles.release(hold)

    {:ok, _} =
      Audit.record(@actor, "bundle.release", hold.channel, %{
        "resource" => hold.channel,
        "last_generation" => hold.resource_generation,
        "version" => hold.version,
        "hash" => hold.hash
      })

    Logger.warning(
      "troupe plane: gitops: the ConfigBundle #{hold.channel} is gone from the cluster: the " <>
        "channel is published by hand again, and v#{hold.version} stays where it was"
    )

    :removed
  end
end
