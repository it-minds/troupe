defmodule Troupe.Operator.WorkerSecrets do
  @moduledoc """
  The Secrets a worker namespace needs, copied into it from the plane's namespace.

  A pod mounts a Secret from its own namespace and no other, and the operator makes that
  namespace, so somebody used to copy each one in by hand for every new profile: the
  object store's credentials, the model key, each bundle MCP server's token, the pull
  secrets and a shared worker certificate. Now each is kept once, in the namespace the
  plane runs in, and every pass copies what the profile needs into its namespace, so a
  rotation there reaches the copies at the next pass, at most a resync later.

  Only what is named, never a pattern, and from two places that are trusted differently:

  - the installation's own names (the object store's Secret, the pull secrets, the
    workers' TLS Secret where no issuer makes one per pod), which come from the chart and
    which nothing a profile says can change, are copied as they are;
  - the names a profile gives (`llm.secretRef`, each MCP server's `secretRef`) are copied
    only from a Secret that says it is for workers, by the label `troupe.dev/worker-secret=true`,
    and, where it also carries `troupe.dev/worker-secret-profiles`, only for the profiles
    that annotation lists. The plane writes profiles, and may not read a Secret: without
    the label, a profile it wrote naming `troupe-plane-database` would have the database's
    password copied to a pod that sends its model key to an endpoint of the profile's
    choosing.

  The source wins. Where it exists and may be copied, the worker namespace's Secret of that
  name is its copy, whoever made one there first. Where it does not, a Secret of that name
  already in the worker namespace is used as it is and left alone, as one External
  Secrets Operator or a person keeps there. Where neither is, it is missing, and the
  profile says so, with the line that fixes it where there is one.

  A copy carries the operator's marker and the profile's label, and goes with the
  namespace. One the profile stops naming is deleted at the next pass, found by the names
  the last pass recorded (`status.copiedSecrets`): the operator reads Secrets by name only,
  and may not list them.
  """

  alias Troupe.Operator.{Names, Settings}
  alias Troupe.WorkerProfile, as: Profile

  require Logger

  @field_manager "troupe-operator"
  @offered "troupe.dev/worker-secret"
  @profiles "troupe.dev/worker-secret-profiles"

  @doc "The label that lets a Secret a profile names be copied to its workers, as `name=value`."
  @spec offered_label() :: String.t()
  def offered_label, do: "#{@offered}=true"

  @doc "The annotation that narrows such a Secret to the profiles it lists, comma-separated."
  @spec profiles_annotation() :: String.t()
  def profiles_annotation, do: @profiles

  @doc "Where a copy says it came from, as `<namespace>/<name>`."
  @spec source_annotation() :: String.t()
  def source_annotation, do: "troupe.dev/copied-from"

  @typedoc """
  What one pass found: the names it copied, the ones it found in the worker namespace and
  left (`kept`), each missing one with why, and the copies it deleted.
  """
  @type outcome :: %{
          copied: [String.t()],
          kept: [String.t()],
          missing: [{String.t(), String.t()}],
          removed: [String.t()]
        }

  @doc "Every Secret a profile's pods need, by name: the installation's, then the profile's."
  @spec names(Profile.t(), Settings.t()) :: [String.t()]
  def names(%Profile{} = profile, %Settings{} = settings),
    do: Enum.uniq(installation(settings) ++ Profile.secret_names(profile))

  # The ones the chart names, which a profile cannot. The TLS Secret is the one every pod's
  # Ingress shares; with an issuer each pod's is made in its own namespace.
  defp installation(%Settings{} = settings) do
    tls = if is_binary(settings.cert_issuer), do: [], else: [settings.tls_secret_name]

    [settings.object_store_secret_name | settings.image_pull_secrets]
    |> Kernel.++(tls)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  @doc """
  Copy every Secret the profile needs into `namespace`, and delete the copies of those it
  no longer names. `previous` is what the last pass copied, from the profile's status.
  """
  @spec sync(K8s.Conn.t(), Profile.t(), Settings.t(), String.t(), [String.t()]) :: outcome()
  def sync(conn, %Profile{} = profile, %Settings{} = settings, namespace, previous) do
    installation = installation(settings)
    wanted = names(profile, settings)
    place = %{conn: conn, profile: profile, from: settings.plane_namespace, to: namespace}

    found =
      Enum.map(wanted, fn name ->
        {name, one(place, name, if(name in installation, do: :installation, else: :profile))}
      end)

    %{
      copied: for({name, :copied} <- found, do: name),
      kept: for({name, :kept} <- found, do: name),
      missing: for({name, {:missing, why}} <- found, do: {name, why}),
      removed: remove(place, List.wrap(previous) -- wanted)
    }
  end

  @doc """
  The names to record as copied after a pass: those it copied, and those an earlier pass
  copied that are still named, whose copy stays while their source is gone for a while.
  """
  @spec recorded(outcome(), [String.t()]) :: [String.t()]
  def recorded(%{copied: copied, kept: kept, missing: missing}, previous) do
    still = Enum.map(missing, &elem(&1, 0)) ++ kept
    Enum.uniq(copied ++ Enum.filter(List.wrap(previous), &(&1 in still)))
  end

  defp one(place, name, whose) do
    case read(place.conn, place.from, name) do
      {:ok, source} ->
        case refusal(source, place.profile, whose) do
          nil -> copy(place, source)
          why -> withdrawn(place, name, why)
        end

      :not_found ->
        present(place, name, "in neither #{place.from}, to copy, nor #{place.to}")

      # The plane's namespace could not be read, which is a permission the chart gives, so
      # an operator from before it, or a role cut down by hand.
      {:error, reason} ->
        present(
          place,
          name,
          "not in #{place.to}, and #{place.from} could not be read to copy it: #{describe(reason)}"
        )
    end
  end

  # Why a Secret a profile names may not be copied to it, or nil where it may.
  defp refusal(_source, _profile, :installation), do: nil

  defp refusal(source, profile, :profile) do
    name = get_in(source, ["metadata", "name"])
    namespace = get_in(source, ["metadata", "namespace"])
    labels = get_in(source, ["metadata", "labels"]) || %{}
    listed = get_in(source, ["metadata", "annotations", @profiles])

    cond do
      labels[@offered] != "true" ->
        "in #{namespace} without #{offered_label()}, which lets the operator copy it to " <>
          "workers: kubectl -n #{namespace} label secret #{name} #{offered_label()}"

      is_binary(listed) and profile.name not in String.split(listed, ~r/[,\s]+/, trim: true) ->
        "in #{namespace} for the profiles #{@profiles} lists (#{listed}), and not #{profile.name}"

      true ->
        nil
    end
  end

  defp copy(place, source) do
    name = get_in(source, ["metadata", "name"])

    copy =
      %{
        "apiVersion" => "v1",
        "kind" => "Secret",
        "metadata" => %{
          "name" => name,
          "namespace" => place.to,
          "labels" => Names.managed_labels(place.profile.name),
          "annotations" => %{source_annotation() => "#{place.from}/#{name}"}
        },
        "type" => source["type"] || "Opaque",
        "data" => source["data"] || %{}
      }

    apply = K8s.Client.apply(copy, field_manager: @field_manager, force: true)

    case K8s.Client.run(place.conn, apply) do
      {:ok, _applied} ->
        :copied

      {:error, reason} ->
        Logger.warning(
          "troupe operator: could not copy #{place.from}/#{name} into #{place.to}: " <>
            inspect(reason)
        )

        {:missing, "could not be copied from #{place.from}: #{describe(reason)}"}
    end
  end

  # A source that may not be copied to this profile, or no longer may: a copy made while it
  # could is taken away, and one somebody else keeps in the worker namespace is theirs.
  defp withdrawn(place, name, why) do
    if ours?(place, name) do
      Logger.info(
        "troupe operator: #{place.from}/#{name} may not be copied to #{place.profile.name}, deleting its copy"
      )

      K8s.Client.run(
        place.conn,
        K8s.Client.delete("v1", "Secret", namespace: place.to, name: name)
      )

      {:missing, why}
    else
      present(place, name, why)
    end
  end

  # Not copied: one already in the worker namespace still serves its pods.
  defp present(place, name, why) do
    case read(place.conn, place.to, name) do
      {:ok, _secret} -> :kept
      _absent -> {:missing, why}
    end
  end

  defp read(conn, namespace, name) do
    case K8s.Client.run(conn, K8s.Client.get("v1", "Secret", namespace: namespace, name: name)) do
      {:ok, secret} -> {:ok, secret}
      {:error, %K8s.Client.APIError{reason: "NotFound"}} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  # Only a Secret this operator copied for this profile: one of the same name that somebody
  # else made, where the source was never there, is theirs.
  defp remove(place, names) do
    for name <- names, ours?(place, name) do
      Logger.info(
        "troupe operator: #{place.profile.name} no longer names #{name}, deleting its copy"
      )

      K8s.Client.run(
        place.conn,
        K8s.Client.delete("v1", "Secret", namespace: place.to, name: name)
      )

      name
    end
  end

  defp ours?(place, name) do
    case read(place.conn, place.to, name) do
      {:ok, secret} ->
        labels = get_in(secret, ["metadata", "labels"]) || %{}

        labels[Names.managed_label()] == "operator" and
          labels["troupe.dev/profile"] == place.profile.name

      _absent ->
        false
    end
  end

  defp describe(%K8s.Client.APIError{reason: reason, message: message}),
    do: "#{reason}: #{message}"

  defp describe(reason), do: inspect(reason)
end
