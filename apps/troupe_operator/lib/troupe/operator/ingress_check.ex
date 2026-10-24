defmodule Troupe.Operator.IngressCheck do
  @moduledoc """
  Whether the ingress controller's namespace carries `troupe.dev/ingress=true`.

  Every worker's NetworkPolicy admits HTTP from namespaces with that label and from nowhere
  else, and so do the plane's, the GUI's and the A2A facade's: it is how "only the ingress
  reaches a pod" is said. Without it every worker Ingress answers 503 and nothing in the
  cluster says why. The operator cannot know which namespace the controller runs in unless
  the installation names it, so:

  - named (the chart's `operator.ingressNamespace`), the operator labels it at every pass
    (`operator.labelIngressNamespace`, on by default), and checks it is there and runs a pod;
  - not named, labelling it is a precondition: the check is that some namespace carries the
    label and runs a pod, and its absence is said with the `kubectl label` line that fixes
    it.

  The answer goes into each profile's `IngressNamespaceMissing` condition, which the plane
  reads with the rest and the console puts under *Needs attention*.
  """

  alias Troupe.Operator.Settings

  require Logger

  @label "troupe.dev/ingress"
  @field_manager "troupe-operator"

  @doc "The label, as `name=value`."
  @spec label() :: String.t()
  def label, do: "#{@label}=true"

  @doc """
  Label the named namespace where the settings say to, then check. `{missing?, reason,
  message}`, as a condition takes it.
  """
  @spec run(K8s.Conn.t(), Settings.t()) :: {boolean(), String.t(), String.t()}
  def run(conn, %Settings{} = settings) do
    named = settings.ingress_namespace

    with :ok <- label_named(conn, named, settings.label_ingress_namespace),
         {:ok, labelled} <- labelled(conn) do
      judge(conn, named, labelled)
    else
      {:not_found, name} ->
        {true, "NamedNamespaceNotFound",
         "the installation names #{name} as the ingress controller's namespace " <>
           "(operator.ingressNamespace), and there is no such namespace; name the one the " <>
           "controller runs in"}

      {:error, reason} ->
        {true, "CheckFailed",
         "could not check which namespace carries #{label()}: #{inspect(reason)}"}
    end
  end

  defp label_named(_conn, nil, _label?), do: :ok
  defp label_named(_conn, _named, false), do: :ok

  # Read first, so a name that is wrong is said rather than made: an apply would create it.
  defp label_named(conn, named, true) do
    case K8s.Client.run(conn, K8s.Client.get("v1", "Namespace", name: named)) do
      {:ok, %{"metadata" => %{"labels" => %{@label => "true"}}}} ->
        :ok

      {:ok, _unlabelled} ->
        namespace = %{
          "apiVersion" => "v1",
          "kind" => "Namespace",
          "metadata" => %{"name" => named, "labels" => %{@label => "true"}}
        }

        apply = K8s.Client.apply(namespace, field_manager: @field_manager, force: true)

        case K8s.Client.run(conn, apply) do
          {:ok, _labelled} ->
            Logger.info("troupe operator: labelled namespace #{named} #{label()}")
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, %K8s.Client.APIError{reason: "NotFound"}} ->
        {:not_found, named}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp labelled(conn) do
    operation =
      "v1"
      |> K8s.Client.list("Namespace")
      |> K8s.Operation.put_selector(K8s.Selector.label({@label, "true"}))

    case K8s.Client.run(conn, operation) do
      {:ok, %{"items" => items}} -> {:ok, Enum.map(items, &get_in(&1, ["metadata", "name"]))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp judge(_conn, named, []) do
    {true, "NoNamespaceLabelled",
     "no namespace carries #{label()}, so no ingress controller may reach a worker and every " <>
       "worker Ingress answers 503. Label the controller's namespace: " <>
       "kubectl label namespace #{named || "<the ingress controller's namespace>"} " <>
       "#{label()}" <> if(named, do: "", else: ", or name it in operator.ingressNamespace")}
  end

  defp judge(conn, named, labelled) do
    if named && named not in labelled do
      {true, "NamedNamespaceUnlabelled",
       "#{named}, the ingress controller's namespace, does not carry #{label()}, so it may " <>
         "not reach a worker and every worker Ingress answers 503: " <>
         "kubectl label namespace #{named} #{label()}"}
    else
      candidates = if named, do: [named], else: labelled

      case Enum.filter(candidates, &running?(conn, &1)) do
        [] ->
          {true, "NoControllerPods",
           "#{Enum.join(candidates, ", ")} carries #{label()} and runs no pod, so the ingress " <>
             "controller is not there; label the namespace it runs in: " <>
             "kubectl label namespace <the ingress controller's namespace> #{label()}"}

        running ->
          {false, "Labelled",
           "#{Enum.join(running, ", ")} carries #{label()} and runs pods, which may reach the workers"}
      end
    end
  end

  # A pod that is running, which the controller's are; a namespace whose only pods have
  # finished does not run the controller.
  defp running?(conn, namespace) do
    case K8s.Client.run(conn, K8s.Client.list("v1", "Pod", namespace: namespace)) do
      {:ok, %{"items" => pods}} ->
        Enum.any?(pods, &(get_in(&1, ["status", "phase"]) == "Running"))

      _unread ->
        false
    end
  end
end
