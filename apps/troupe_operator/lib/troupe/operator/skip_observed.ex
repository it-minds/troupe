defmodule Troupe.Operator.SkipObserved do
  @moduledoc """
  Halts a watch event that only restates what the last pass already ran.

  `Bonny.Pluggable.SkipObservedGenerations` halts an added or modified resource whose
  `metadata.generation` is the `status.observedGeneration` a pass wrote, which is every
  event a status write makes. That is right for the spec, and wrong for a profile that
  extends another: the plane resolves it into its status (`status.effective`), so a change
  to its parent reaches it as a status write and no new generation. Such a profile is
  halted only once the pass has also run the resolution it carries, which the pass records
  as `status.effectiveRevision`; a new one goes through at once rather than at the next
  resync.

  The same for the plane's record of the pods it has finished draining, an annotation
  (`troupe.dev/drained`), which no generation counts either: a resource is halted only
  once the pass has acted on the record it carries, which the pass writes as
  `status.drainedRevision`, so the pod a drain has emptied is replaced when the plane says
  so rather than half a minute later.

  Nothing else is different, and the resync (`:reconcile`) always goes through.
  """

  @behaviour Pluggable

  import Pluggable.Token

  alias Bonny.Axn
  alias Troupe.WorkerProfile

  @actions [:add, :modify]

  @impl Pluggable
  def init(opts), do: opts

  @impl Pluggable
  def call(%Axn{action: action, resource: resource} = axn, _opts) when action in @actions do
    if observed?(resource), do: halt(axn), else: axn
  end

  def call(axn, _opts), do: axn

  @doc "Whether a pass has already run this resource as it now is."
  @spec observed?(map()) :: boolean()
  def observed?(resource) do
    generation = get_in(resource, ["metadata", "generation"])

    generation == get_in(resource, ["status", "observedGeneration"]) and
      (is_nil(WorkerProfile.extends(resource)) or
         WorkerProfile.effective_revision(resource) ==
           get_in(resource, ["status", "effectiveRevision"])) and
      WorkerProfile.drained_revision(resource) == get_in(resource, ["status", "drainedRevision"])
  end
end
