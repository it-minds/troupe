defmodule Troupe.Plane.Gitops do
  @moduledoc """
  In GitOps mode the cluster's resources are what the plane runs on (Decision 736).

  A repository holds the manifests, something else — Flux, in our own deployment —
  applies them to the cluster, and the plane reads them there. It never writes git, holds
  no credential for a repository and does not know where one is beyond the sentence
  `gitops_source` gives it to show. What the plane keeps of each resource is a row, as it
  always has, because placement and the scaler cannot ask the API server on every
  request; the difference is that in this mode the row follows the resource instead of
  the resource following the row.

  ## A tick, not a watch

  Every fifteen seconds, one cluster singleton lists each kind in the plane's namespace
  and reconciles the rows against the list: a resource with no row becomes one, a
  changed resource changes its row, a row whose resource has gone goes. A watch would
  see a change a few seconds sooner and cost a long-lived connection, resourceVersion
  bookkeeping, and a relist after every `410 Gone` — machinery for a change that arrives
  at the rate somebody merges a pull request, after Flux's own interval. A list also
  answers the one question a watch cannot without one: what is *not* there. A plane that
  was down or partitioned is right again at its first tick, with nothing to replay.

  ## What a pass cannot use

  Each resource is read with the plane's own checks before anything is written, and one
  that fails them is reported — in `gitops_reports`, in the log once, in
  `admin.profiles.list` or `admin.triggers.list` and on the console — instead of used. A new one gets no row; a
  changed one leaves the row as the last version that passed, so a typo in a repository
  does not take down a profile that was running. A row the cluster has no resource for is
  reported too, unless it followed one that has since gone, in which case it goes with it.

  ## Another kind

  A kind joins by implementing this behaviour and being listed in `sources/0`. The
  engine lists, reads, reports and removes; the source knows what a row is, what its
  checks are and what writing one means. `Troupe.Plane.Gitops.Profiles` is the first and
  `Troupe.Plane.Gitops.Triggers` the second (Decision 737), in that order, so that a pass
  reads a trigger after the profile it names.
  """

  use GenServer

  import Ecto.Query

  alias Troupe.Plane.{ClusterPolicy, Provision, Repo, Settings, Singleton}
  alias Troupe.Plane.Gitops.{Profiles, Report, Triggers}

  require Logger

  @tick_ms 15_000

  @typedoc "What a pass made of one resource or one row."
  @type outcome :: %{
          name: String.t(),
          state: :created | :changed | :unchanged | :refused | :removed | :missing,
          generation: integer() | nil,
          problem: String.t() | nil,
          reasons: [String.t()]
        }

  @doc "The kind of resource, as the API server names it: `WorkerProfile`."
  @callback kind() :: String.t()

  @doc "Its API version: `troupe.dev/v1alpha1`."
  @callback api_version() :: String.t()

  @doc "The plane's rows for this kind, by name."
  @callback rows() :: %{String.t() => struct()}

  @doc "Anything a pass reads once for every resource, such as the cluster policy."
  @callback context() :: term()

  @doc """
  One resource, checked: the attributes of its row, or every reason it cannot be used, as
  sentences. Nothing is written here.
  """
  @callback read(resource :: map(), context :: term()) ::
              {:ok, map()} | {:error, [String.t()]}

  @doc """
  Make the row say what a resource that passed says, and anything else that follows.
  Answers what became of the row and, where the resource is used but something about it
  still needs a person, a problem to report with its reasons.
  """
  @callback take(name :: String.t(), attrs :: map(), row :: struct() | nil, resource :: map()) ::
              {:created | :changed | :unchanged, nil | {String.t(), [String.t()]}}

  @doc """
  A row the cluster has no resource for: `:removed` where it followed one that has gone,
  or `{:missing, reasons}` where no resource was ever read into it.
  """
  @callback gone(row :: struct()) :: :removed | {:missing, [String.t()]}

  @doc "Every kind a pass reads."
  @spec sources() :: [module()]
  def sources, do: [Profiles, Triggers]

  @doc """
  Where the resources come from, as a person should read it: the repository and path the
  deployment named (`gitops_source`), or `nil` where it named none. Display only.
  """
  @spec source() :: String.t() | nil
  def source, do: Settings.get("gitops_source")

  @doc "Whether this plane is in GitOps mode."
  @spec enabled?() :: boolean()
  def enabled?, do: Provision.mode() == :gitops

  # -- a pass -----------------------------------------------------------------

  @doc "One pass over every kind: what became of each resource and each row, by kind."
  @spec sync_all() :: %{String.t() => {:ok, [outcome()]} | {:error, term()}}
  def sync_all, do: Map.new(sources(), &{&1.kind(), sync(&1)})

  @doc """
  One pass over one kind.

  A list that fails is an error and changes nothing. It must never read as an empty
  list: that would be every resource removed from the repository at once, and every row
  that followed one would go.
  """
  @spec sync(module()) :: {:ok, [outcome()]} | {:error, term()}
  def sync(source) do
    with {:ok, resources} <- list(source) do
      rows = source.rows()
      context = source.context()
      listed = MapSet.new(resources, &name_of/1)

      outcomes =
        Enum.map(resources, &take(source, &1, Map.get(rows, name_of(&1)), context)) ++
          for {name, row} <- rows, not MapSet.member?(listed, name), do: gone(source, name, row)

      remember(source.kind(), outcomes)
      {:ok, outcomes}
    end
  end

  # One resource at a time, and one that raises is that resource's problem: reported like
  # a refusal, with the row as it was, and the rest of the pass goes on. A pass that one
  # bad manifest could stop would be every profile frozen by one typo.
  defp take(source, resource, row, context) do
    name = name_of(resource)
    generation = get_in(resource, ["metadata", "generation"])

    case source.read(resource, context) do
      {:ok, attrs} ->
        {state, problem} = source.take(name, attrs, row, resource)
        outcome(name, state, generation, problem)

      {:error, reasons} ->
        outcome(name, :refused, generation, {"refused", reasons})
    end
  rescue
    exception ->
      failed(source, name_of(resource), get_in(resource, ["metadata", "generation"]), exception)
  end

  defp gone(source, name, row) do
    case source.gone(row) do
      :removed -> outcome(name, :removed, nil, nil)
      {:missing, reasons} -> outcome(name, :missing, nil, {"missing", reasons})
    end
  rescue
    exception -> failed(source, name, nil, exception)
  end

  defp failed(source, name, generation, exception) do
    Logger.error(
      "troupe plane: gitops: reading #{source.kind()} #{name} failed: #{Exception.message(exception)}"
    )

    outcome(
      name,
      :refused,
      generation,
      {"refused", ["the plane failed reading it: #{Exception.message(exception)}"]}
    )
  end

  defp outcome(name, state, generation, nil),
    do: %{name: name, state: state, generation: generation, problem: nil, reasons: []}

  defp outcome(name, state, generation, {problem, reasons}),
    do: %{name: name, state: state, generation: generation, problem: problem, reasons: reasons}

  defp name_of(resource), do: get_in(resource, ["metadata", "name"])

  # An exit is an answer, as it is for `Provision`: the client calls processes of its
  # own, and a cluster that did not answer must not take the pass down with it.
  defp list(source) do
    with {:ok, conn} <- Provision.connection() do
      operation =
        K8s.Client.list(source.api_version(), source.kind(), namespace: Provision.namespace())

      case K8s.Client.run(conn, operation) do
        {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
        {:ok, %{"items" => nil}} -> {:ok, []}
        {:ok, other} -> {:error, {:unexpected_list, other}}
        {:error, reason} -> {:error, reason}
      end
    end
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # -- reports ----------------------------------------------------------------

  @doc "What the last pass could not use or could not find, for one kind, by name."
  @spec reports(String.t()) :: [Report.t()]
  def reports(kind) do
    Repo.all(from(r in Report, where: r.kind == ^kind, order_by: r.name))
  end

  @doc "The report for one resource or row, or `nil` where there is none."
  @spec report(String.t(), String.t()) :: Report.t() | nil
  def report(kind, name), do: Repo.get_by(Report, kind: kind, name: name)

  @doc "Drop one report, for a row that has been dealt with before the next pass."
  @spec forget(String.t(), String.t()) :: :ok
  def forget(kind, name) do
    Repo.delete_all(from(r in Report, where: r.kind == ^kind and r.name == ^name))
    :ok
  end

  # Replaced as a whole for the kind, so a report goes the pass its cause does. Said in the
  # log when it is new or has changed and not on every pass: fifteen seconds of the same
  # warning is a log nobody reads by the afternoon.
  defp remember(kind, outcomes) do
    now =
      for %{problem: problem} = outcome <- outcomes,
          problem,
          into: %{},
          do: {outcome.name, outcome}

    before = Map.new(reports(kind), &{&1.name, &1})

    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(
          from(r in Report, where: r.kind == ^kind and r.name not in ^Map.keys(now))
        )

        for {name, outcome} <- now do
          Repo.insert!(
            %Report{
              kind: kind,
              name: name,
              problem: outcome.problem,
              generation: outcome.generation,
              reasons: outcome.reasons
            },
            on_conflict: {:replace, [:problem, :generation, :reasons, :updated_at]},
            conflict_target: [:kind, :name]
          )
        end
      end)

    for {name, outcome} <- now, changed?(Map.get(before, name), outcome) do
      Logger.warning(
        "troupe plane: gitops: #{kind} #{name} #{describe(outcome)}: " <>
          Enum.join(outcome.reasons, "; ")
      )
    end

    for name <- Map.keys(before), not Map.has_key?(now, name) do
      Logger.info("troupe plane: gitops: #{kind} #{name} is no longer reported")
    end

    :ok
  end

  defp changed?(nil, _outcome), do: true

  defp changed?(%Report{} = report, outcome),
    do:
      {report.problem, report.generation, report.reasons} !=
        {outcome.problem, outcome.generation, outcome.reasons}

  defp describe(%{problem: "refused", generation: generation}),
    do: "at generation #{generation} is not used"

  defp describe(%{problem: "missing"}), do: "has no resource in the cluster"
  defp describe(%{problem: problem}), do: "needs attention (#{problem})"

  # -- who wrote what ---------------------------------------------------------

  @doc """
  The field managers that own a path of a resource's spec or metadata, from
  `metadata.managedFields`: `["spec", "replicas"]`, `["metadata", "annotations",
  "troupe.dev/drained"]`. A status subresource's entry is not the resource's and is left
  out.
  """
  @spec managers(map(), [String.t()]) :: [String.t()]
  def managers(resource, path) do
    fields = Enum.map(path, &("f:" <> &1))

    for entry <- get_in(resource, ["metadata", "managedFields"]) || [],
        is_nil(entry["subresource"]),
        is_map(get_in(entry, ["fieldsV1" | fields])),
        do: entry["manager"]
  end

  @doc "Whether a resource says who wrote it at all. An API server's always does."
  @spec tracked?(map()) :: boolean()
  def tracked?(resource), do: (get_in(resource, ["metadata", "managedFields"]) || []) != []

  @doc "Whether a field manager is the plane: `troupe-plane` and `troupe-plane-upgrade`."
  @spec plane?(String.t() | nil) :: boolean()
  def plane?(manager) when is_binary(manager), do: String.starts_with?(manager, "troupe-plane")
  def plane?(_manager), do: false

  # -- bootstrapping a repository ----------------------------------------------

  @doc """
  The manifests a repository would hold, as they would be committed: every profile, the
  cluster policy and every trigger (`admin.profiles.export`).

  Built from the plane's rows, which in direct mode are the truth and in GitOps mode are
  what the plane last read, and with nothing in them the plane or the cluster writes.
  """
  @spec export() :: map()
  def export do
    %{
      profiles: Profiles.export(),
      policy: ClusterPolicy.export(),
      triggers: Triggers.export(),
      left_out: Profiles.left_out()
    }
  end

  @runtime_metadata ~w(managedFields resourceVersion uid generation creationTimestamp selfLink
                       finalizers ownerReferences deletionTimestamp deletionGracePeriodSeconds)

  # Keys a tool or the plane writes and a repository should not: the last applied
  # configuration of `kubectl apply`, Helm's release bookkeeping, Flux's own labels, and
  # the plane's record of finished drains, which an applier that owned it would put back.
  @runtime_prefixes ~w(kubectl.kubernetes.io/ meta.helm.sh/ helm.sh/ kustomize.toolkit.fluxcd.io/)
  @runtime_keys ~w(troupe.dev/drained troupe.dev/managed-by app.kubernetes.io/managed-by
                   app.kubernetes.io/instance app.kubernetes.io/version)

  @doc """
  A resource without what the cluster and the tools that wrote it keep on it: its
  `status`, the metadata the API server fills in (`managedFields`, `resourceVersion`,
  `uid`, `generation`, `creationTimestamp` and the rest), and the labels and annotations
  `kubectl`, Helm, Flux and the plane put there for themselves, the plane's
  `troupe.dev/drained` among them.
  """
  @spec strip(map()) :: map()
  def strip(resource) do
    metadata =
      (resource["metadata"] || %{})
      |> Map.drop(@runtime_metadata)
      |> strip_keys("labels")
      |> strip_keys("annotations")

    resource
    |> Map.take(["apiVersion", "kind", "spec"])
    |> Map.put("metadata", metadata)
  end

  defp strip_keys(metadata, field) do
    kept =
      (metadata[field] || %{})
      |> Map.reject(fn {key, _value} ->
        key in @runtime_keys or Enum.any?(@runtime_prefixes, &String.starts_with?(key, &1))
      end)

    if kept == %{}, do: Map.delete(metadata, field), else: Map.put(metadata, field, kept)
  end

  @doc "A manifest as a file in a repository holds it, with any notes as comments above it."
  @spec yaml(map(), [String.t()]) :: String.t()
  def yaml(manifest, []), do: Ymlr.document!(manifest)
  def yaml(manifest, notes), do: Ymlr.document!({notes, manifest})

  # -- the process that runs the passes -----------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc "The cluster's pass, started if nobody has."
  @spec ensure() :: {:ok, pid()} | {:error, term()}
  def ensure, do: Singleton.whereis(__MODULE__, :gitops)

  @impl GenServer
  def init(opts) do
    Process.set_label("troupe gitops")
    interval = Keyword.get(opts, :interval_ms, @tick_ms)
    send(self(), :tick)
    {:ok, %{interval_ms: interval, failed: nil}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = if enabled?(), do: pass(state), else: state
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A pass that raises — the database not there yet, most likely — must not take the
  # process with it; the next is fifteen seconds away. A cluster that will not list is
  # said once when it starts and once when it stops, not every tick.
  defp pass(state) do
    failed =
      sync_all()
      |> Enum.flat_map(fn
        {kind, {:error, reason}} -> [{kind, reason}]
        {_kind, {:ok, _outcomes}} -> []
      end)

    cond do
      failed == state.failed ->
        :ok

      failed == [] ->
        Logger.info("troupe plane: gitops: the cluster answers again")

      true ->
        Logger.warning(
          "troupe plane: gitops: could not read " <>
            Enum.map_join(failed, "; ", fn {kind, reason} -> "#{kind}: #{inspect(reason)}" end)
        )
    end

    %{state | failed: failed}
  rescue
    exception ->
      Logger.error("troupe plane: gitops pass failed: #{Exception.message(exception)}")
      state
  end

  defmodule Keeper do
    @moduledoc """
    Asks for the cluster's GitOps pass on a timer, from every replica.

    The scaler's keeper, for the same reason: the singleton idiom starts an actor when it
    is first asked for, and nothing asks for this one on the way to anything else.
    """

    use GenServer

    alias Troupe.Plane.Gitops

    @ask_ms 30_000

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl GenServer
    def init(opts) do
      Process.set_label("troupe gitops keeper")
      interval = Keyword.get(opts, :interval_ms, @ask_ms)
      send(self(), :ask)
      {:ok, %{interval_ms: interval}}
    end

    @impl GenServer
    def handle_info(:ask, state) do
      Gitops.ensure()
      Process.send_after(self(), :ask, state.interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
