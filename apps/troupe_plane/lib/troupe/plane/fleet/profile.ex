defmodule Troupe.Plane.Fleet.Profile do
  @moduledoc """
  What the plane remembers about a `WorkerProfile` it wrote, or in GitOps mode read.

  A cache of desired state so placement can answer "how many sessions fit" without
  asking Kubernetes on every create. The custom resource is the source of truth and the
  operator reads only that; this row is written whenever the plane writes the resource,
  and in GitOps mode whenever the plane reads a new version of it (Decision 736).

  Three of these fields are an administrator's and the rest are derived. `size_class`
  says how demanding a session is here, `max_sessions` how far this may grow — in
  sessions at once, not workers — and `warm_workers` whether to keep one up when nothing
  is running. `replicas`, `sessions_per_pod` and the resource and storage numbers in
  `spec` follow from the class and from what is actually running, and the plane writes
  them the way it already writes `spec.teams`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Troupe.Plane.Fleet.{Provisioner, SizeClass}
  alias Troupe.Plane.GitHub
  alias Troupe.Protocol.ProviderTypes

  @primary_key {:name, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :name}

  schema "profiles" do
    field :replicas, :integer, default: 1
    field :sessions_per_pod, :integer, default: 4

    # What an administrator actually answers.
    field :size_class, :string, default: "standard"
    # `nil` is no ceiling, bounded by the team's money. A ceiling is a decision somebody
    # makes, and a default would be a refusal nobody chose.
    field :max_sessions, :integer
    field :warm_workers, :integer, default: 0
    # When the last session here stopped being active, so scale-to-zero waits rather
    # than removing a worker the instant somebody's session goes dormant.
    field :idle_since, :utc_datetime_usec
    # Which substrate the workers come from. An administrator's answer, and the only field
    # here that decides what guarantees a session on this profile gets — which is why what
    # those guarantees *are* is asked of the provisioner rather than stored beside this.
    field :provisioner, :string, default: "kubernetes"
    field :config_bundle_channel, :string, default: "stable"
    field :image, :string
    field :workers_domain, :string
    field :spec, :map, default: %{}
    # In GitOps mode, the generation of the `WorkerProfile` this row was last read from,
    # and `nil` for a row no resource has been read into (Decision 736). A row with one
    # goes when its resource does; a row without one is reported and kept.
    field :resource_generation, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # The one list of casts both changesets share, so a field added to the row cannot be
  # writable by an administrator and silently dropped when the row is read from a resource.
  @fields [
    :name,
    :replicas,
    :sessions_per_pod,
    :size_class,
    :max_sessions,
    :warm_workers,
    :idle_since,
    :provisioner,
    :config_bundle_channel,
    :image,
    :workers_domain,
    :spec
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @fields)
    |> validate()
    |> derive_from_class()
  end

  @doc """
  A row as a `WorkerProfile` in the cluster says it is, in GitOps mode (Decision 736).

  `changeset/2` and the generation it was read at, which only this may write: a caller of
  the admin API that sent one would be marking a row as following a resource it never
  came from. The class is read off the resource's own `sessionsPerPod`, which a resource
  may only give as a class's number, so deriving the number from it again changes nothing.
  """
  @spec cluster_changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def cluster_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:resource_generation | @fields])
    |> validate()
    |> derive_from_class()
  end

  defp validate(changeset) do
    changeset
    |> validate_required([:name])
    |> validate_number(:sessions_per_pod, greater_than: 0)
    |> validate_inclusion(:size_class, SizeClass.names())
    |> validate_inclusion(:provisioner, Provisioner.names())
    |> validate_number(:max_sessions, greater_than: 0)
    |> validate_number(:warm_workers, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_change(:spec, &spec_switches/2)
    |> check_constraint(:provisioner, name: :profiles_provisioner)
  end

  # `repositoryOverridesBundle` lets a repository's agents and skills replace the bundle's,
  # and the built-ins, of the same name on this profile's pods, where otherwise theirs win
  # and the working copy's are skipped and listed; it is read as on only when it is
  # `true`. A string `"true"` would read as off, so it is refused rather than saved: a
  # profile whose admin believes they turned something on must not quietly have it off.
  # The resource's schema refuses one too, and this is the check for a profile that is
  # never one, on hosts.
  #
  # `personalTools` says whether a person may offer a session on the profile's pods their
  # own signed-in tools, which the pods refuse with a sentence when it forbids them:
  # `allow`, the default, or `forbid`. Anything else is refused for the same reason: a pod
  # reads only `forbid` as forbidding, and a `"Forbid"` saved would leave the pods taking
  # what the admin believes they refuse.
  defp spec_switches(:spec, spec) when is_map(spec) do
    overrides =
      case Map.fetch(spec, "repositoryOverridesBundle") do
        {:ok, value} when not is_boolean(value) ->
          [spec: "repositoryOverridesBundle must be true or false, not #{inspect(value)}"]

        _absent_or_boolean ->
          []
      end

    personal =
      case Map.fetch(spec, "personalTools") do
        {:ok, value} when value not in ["allow", "forbid"] ->
          [spec: "personalTools must be allow or forbid, not #{inspect(value)}"]

        _absent_or_known ->
          []
      end

    # `github.permissions` is what the profile's sessions' fix-loop token may do on GitHub,
    # in GitHub's own names. A name or a level it may not grant is refused rather than
    # dropped: a profile saved with `contents: Write` would push nothing, and one with
    # `administration: write` would be asking for what no session is given.
    github = Enum.map(GitHub.spec_problems(Map.get(spec, "github")), &{:spec, &1})

    overrides ++ personal ++ github ++ llm_problems(Map.get(spec, "llm"))
  end

  defp spec_switches(:spec, _spec), do: []

  # `llm.provider` is one of the provider types, the list the clients offer, which the
  # resource's schema declares in the same words, so a profile that is never a resource,
  # on hosts, is refused where a resource would be.
  #
  # And every other `llm` field needs `llm.endpoint`. The operator hands the pods the
  # `llm` settings only with an endpoint, so without one a provider, a model or a key
  # would be a setting that silently does nothing while the pods run on the built-in
  # model settings. It is refused instead, naming the fields, as the resource's schema
  # refuses it.
  @llm_fields ~w(provider model smallModel secretRef prices)

  defp llm_problems(llm) when is_map(llm), do: llm_type(llm["provider"]) ++ llm_endpoint(llm)
  defp llm_problems(_llm), do: []

  defp llm_type(nil), do: []

  defp llm_type(provider) do
    if provider in ProviderTypes.names() do
      []
    else
      names = Enum.join(ProviderTypes.names(), ", ")
      [spec: "llm.provider must be one of #{names}, not #{inspect(provider)}"]
    end
  end

  defp llm_endpoint(llm) do
    set = for field <- @llm_fields, llm[field] not in [nil, "", %{}, []], do: "llm." <> field

    if set == [] or llm["endpoint"] not in [nil, ""] do
      []
    else
      {verb, pronoun} = if length(set) == 1, do: {"is", "it"}, else: {"are", "them"}

      [
        spec:
          "#{listed(set)} #{verb} set without llm.endpoint, and the pods are given the llm " <>
            "settings only with an endpoint: without one they would run on Troupe's built-in " <>
            "model settings instead. Set llm.endpoint, or take #{pronoun} out"
      ]
    end
  end

  defp listed([one]), do: one
  defp listed(many), do: Enum.join(Enum.drop(many, -1), ", ") <> " and " <> List.last(many)

  @doc "The `llm` fields a profile may set only beside `llm.endpoint`, as the resource names them."
  @spec llm_fields() :: [String.t()]
  def llm_fields, do: @llm_fields

  # The class is the answer, so the fields it decides are written from it rather than
  # taken from the caller. A profile whose `sessionsPerPod` disagreed with its class
  # would be a profile with two opinions about the same number, and the one an
  # administrator could see would be the wrong one.
  defp derive_from_class(changeset) do
    class = get_field(changeset, :size_class)

    if SizeClass.valid?(class) do
      put_change(changeset, :sessions_per_pod, SizeClass.sessions_per_pod(class))
    else
      changeset
    end
  end
end
