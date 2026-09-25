defmodule Troupe.Plane.Fleet.Provisioner do
  @moduledoc """
  What makes a worker exist, behind an interface.

  Today a worker is a pod and a pod needs a cluster, which makes Troupe's first target
  shape — *feels like running your own instance* — served by the daemon alone: no
  placement, no bundles, no team. This is the seam that lets the same session, the same
  bundle and the same seal run on a machine somebody already has.

  The boundary was nearly drawn already, which is why this is an interface rather than a
  rewrite. The operator reconciles infrastructure and the plane places sessions, and they
  talk through a document. Enrolment is a token and a namespace. The control channel is
  JSON-RPC and carries no content. Nothing in placement knows what a pod is except through
  the capacity and health reported over that channel.

  ## What does not change, and is the whole point

    * **Enrolment still proves the worker is the profile it claims.** For Kubernetes that
      is a `TokenReview` against a namespace. For anything else it is a secret issued at
      registration and rotatable. Same method, same refusal — a worker that cannot prove
      it is not enrolled, and the refusal does not say which check it failed.
    * **The control channel, seal format, object layout, key paths and session log are
      byte-identical.** A session sealed by one kind of worker restores on another. That
      is a W1 done item and it exists for exactly this.
    * **Placement reasons in workers.** Capacity, health, drain state and disk watermark
      are reported the same way by every provisioner, so `Troupe.Plane.Placement` never
      learns there is more than one.

  ## What does change is said plainly rather than implied

  A worker outside Kubernetes does not have the guarantees Kubernetes was providing: no
  admission policy, no NetworkPolicy, no FQDN egress, no disruption budget. That is not a
  footnote to put in a migration guide. `guarantees/0` is how a provisioner says which of
  them it actually offers, the console names the missing ones, and the policy ladder
  refuses to place a team on such a profile without a platform admin having said so.

  This is for the developer with one laptop and the team with one build box. It is not a
  way around the policy, and the interface is shaped so that it cannot quietly become one.
  """

  alias Troupe.Plane.Fleet.{Profile, Worker}

  @typedoc "One worker the substrate knows about, whether or not it has enrolled."
  @type worker_ref :: %{
          required(:name) => String.t(),
          required(:profile) => String.t(),
          optional(:address) => String.t() | nil,
          optional(:ordinal) => non_neg_integer() | nil
        }

  @typedoc """
  What a substrate guarantees about the workers it makes.

  Named individually because done item 3 is that the console says *which* guarantee is
  missing. "Unenforced" is not a useful thing to tell somebody who has to decide whether
  their team's session may run there.

  `egress_checked_at_admission` is the weaker one a Kubernetes profile has without Cilium:
  the allowlist is checked when the profile is admitted and at every reconcile, and not on
  the wire, where a worker reaches any public host on 443 and 80. It stands in for
  `fqdn_egress` rather than being counted as it.
  """
  @type guarantee ::
          :admission_policy
          | :network_policy
          | :fqdn_egress
          | :egress_checked_at_admission
          | :disruption_budget

  @guarantees ~w(admission_policy network_policy fqdn_egress disruption_budget)a

  # A weaker guarantee a provisioner may give where it cannot give one of the above, and
  # the one it stands in for. Named so that what a profile has can be said exactly,
  # rather than rounded up to the stronger guarantee or down to nothing.
  @weaker %{egress_checked_at_admission: :fqdn_egress}

  @doc """
  Every guarantee a profile can be missing.

  A weaker one given in place of one of these does not count as it: the profile is still
  missing the stronger one, and `account/1` says what stands in.
  """
  @spec guarantees() :: [guarantee()]
  def guarantees, do: @guarantees

  @doc """
  Make this profile have the workers it asks for.

  Idempotent and declarative: the profile's `replicas` is the number wanted, and calling
  this twice with the same profile is one request. It does not wait — a worker exists when
  it has enrolled, which the plane learns over the control channel like everything else.
  """
  @callback ensure(Profile.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Take one worker out of service, and say whether it is safe to remove.

  The sequence is `Troupe.Plane.Drain`'s and is the same everywhere — stop placing, let
  running turns finish, get everything into object storage. What differs is what happens
  to the machine afterwards, and for some substrates the answer is nothing at all.

  Nothing here removes anything from object storage. That is done item 4 and it is a
  property of the sequence rather than of any one provisioner.
  """
  @callback drain(Worker.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  What the substrate says exists, as against what has enrolled.

  The difference is the interesting part: a worker the substrate has and the plane has not
  heard from is one that is still coming up or has failed to start, and those are different
  from a worker nobody asked for.
  """
  @callback describe(Profile.t()) :: {:ok, [worker_ref()]} | {:error, term()}

  @doc "Which of the guarantees this substrate actually provides."
  @callback guarantees(Profile.t()) :: [guarantee()]

  @doc """
  The name an administrator sees and a profile row stores.

  A string rather than a module: the row outlives any particular module name, and a
  profile that named a module would be a row that stopped loading when somebody renamed
  one.
  """
  @callback name() :: String.t()

  @doc """
  The provisioner a profile uses.

  `kubernetes` for anything that does not say, which is every profile that existed before
  this and the right default for anything created by an operator that does not know the
  question.
  """
  @spec for(Profile.t() | String.t() | nil) :: module()
  def for(%Profile{provisioner: name}), do: __MODULE__.for(name)
  def for(nil), do: __MODULE__.Kubernetes

  def for(name) when is_binary(name) do
    Enum.find(implementations(), __MODULE__.Kubernetes, &(&1.name() == name))
  end

  @doc "Every provisioner this plane can use."
  @spec implementations() :: [module()]
  def implementations, do: [__MODULE__.Kubernetes, __MODULE__.SSH]

  @doc "The names an administrator may choose between."
  @spec names() :: [String.t()]
  def names, do: Enum.map(implementations(), & &1.name())

  @doc "Whether this is one of them."
  @spec known?(term()) :: boolean()
  def known?(name), do: name in names()

  @doc """
  The guarantees a profile does *not* get, which is what somebody needs told.

  Against the full set rather than against another provisioner: "fewer than Kubernetes"
  is a comparison, and what a person deciding needs is a list of what is missing.
  """
  @spec missing(Profile.t()) :: [guarantee()]
  def missing(%Profile{} = profile), do: account(profile).missing

  @doc """
  Whether a guarantee is missing with nothing in its place, which is what the ladder
  refuses a team on without a platform admin's say-so.

  A weaker guarantee in place of a missing one is enough here: a Kubernetes profile
  without Cilium still has its allowlist enforced at admission, and is not the build box
  the ladder exists for. It is still missing egress by hostname, and says so.
  """
  @spec unenforced?(Profile.t()) :: boolean()
  def unenforced?(%Profile{} = profile), do: account(profile).unenforced

  @doc """
  What a profile's workers get, asked of its provisioner once.

  `given` is what the provisioner guarantees, weaker ones included; `missing` is every
  guarantee it does not give; `instead` maps a missing one to the weaker one given in its
  place; and `unenforced` is whether any is missing with nothing instead. One call, because
  a Kubernetes provisioner asks the cluster to answer.
  """
  @spec account(Profile.t()) :: %{
          given: [guarantee()],
          missing: [guarantee()],
          instead: %{guarantee() => guarantee()},
          unenforced: boolean()
        }
  def account(%Profile{} = profile) do
    given = __MODULE__.for(profile).guarantees(profile)
    missing = @guarantees -- given

    instead =
      for weaker <- given, Map.get(@weaker, weaker) in missing, into: %{} do
        {Map.fetch!(@weaker, weaker), weaker}
      end

    %{
      given: given,
      missing: missing,
      instead: instead,
      unenforced: missing -- Map.keys(instead) != []
    }
  end
end
