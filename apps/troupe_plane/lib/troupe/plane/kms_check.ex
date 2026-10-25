defmodule Troupe.Plane.KMSCheck do
  @moduledoc """
  Whether the plane's OpenBao credential may do what the plane does with it, asked without
  doing any of it.

  The plane cannot write its own policies: that takes an OpenBao administrator, which the
  plane never is. So what its role must be granted is a precondition, and this checks it:
  once as the plane starts, in its log, and on the console's Overview
  (`Troupe.Plane.Admin.overview/1`), so a missing grant is a sentence and the lines that
  add it rather than the first signed answer or the first session failing with a 403.

  Look-only. `sys/capabilities-self` answers what the plane's own token may do at each
  path, which the `default` policy every login carries allows, and `auth/token/lookup-self`
  which policies the token carries now, so the printed lines keep them. What is asked is
  `Troupe.KMS.Policy.plane_grants/1`, the one list the docs page is written from too.

  The GitHub App's grant is the list's one optional grant, and it is optional only while
  the plane has no App: once one is set up (`Troupe.Plane.GitHub.configured?/0`), missing
  it stops the App signing, so it is required and the plane is not healthy without it.
  """

  alias Troupe.KMS.Policy
  alias Troupe.Plane.{GitHub, Signing, Tokens}
  alias Troupe.Plane.GitHub.{Key, WebhookSecret}

  require Logger

  # Short, because the console's Overview waits on it: an OpenBao that does not answer is
  # said in a sentence, not in a page that does not load.
  @timeout_ms 3_000

  @typedoc "One grant, checked: the grant's own fields and what this token was found to hold."
  @type verdict :: %{
          id: String.t(),
          policy: String.t(),
          required: boolean(),
          ok: boolean(),
          detail: String.t(),
          missing: [%{path: String.t(), capabilities: [String.t()]}],
          fix: String.t() | nil
        }

  @doc """
  Every grant, checked. `ok` is whether every required one is held; `error` is a sentence
  where the check itself could not be made, with `fix` where something can be done about it.
  """
  @spec run(keyword()) :: %{
          ok: boolean(),
          error: String.t() | nil,
          fix: String.t() | nil,
          grants: [verdict()]
        }
  def run(opts \\ []) do
    grants = Enum.map(Policy.plane_grants(names()), &required_now/1)
    config = Application.get_env(:troupe_plane, :transit, [])

    paths =
      grants
      |> Enum.flat_map(& &1.rules)
      |> Enum.map(&Policy.probe_path(elem(&1, 0)))
      |> Enum.uniq()

    request = Keyword.merge([receive_timeout: @timeout_ms], opts)

    case Tokens.request(:post, "/v1/sys/capabilities-self", %{"paths" => paths}, request) do
      {:ok, body} ->
        held = held(body, paths)
        attach = attach(config, policies(request))
        verdicts = Enum.map(grants, &verdict(&1, held, attach))

        %{
          ok: Enum.all?(verdicts, &(&1.ok or not &1.required)),
          error: nil,
          fix: nil,
          grants: verdicts
        }

      {:error, reason} ->
        {error, fix} = unchecked(reason, config, grants)
        %{ok: false, error: error, fix: fix, grants: []}
    end
  end

  @doc "Run the check and say in the log what is missing, a line per grant. At start."
  @spec log() :: :ok
  def log do
    case run() do
      %{error: error} when is_binary(error) ->
        Logger.warning("troupe plane: OpenBao: #{error}")

      %{grants: verdicts} ->
        verdicts |> Enum.reject(& &1.ok) |> log_missing()
    end

    :ok
  end

  defp log_missing([]),
    do: Logger.info("troupe plane: OpenBao: the plane's role holds every grant it needs")

  defp log_missing(missing) do
    for verdict <- missing do
      Logger.warning("troupe plane: OpenBao: #{verdict.detail} To grant it:\n#{verdict.fix}")
    end
  end

  # The App's grant is needed only for an App, and needed once there is one.
  defp required_now(%{id: "github-app"} = grant), do: %{grant | required: GitHub.configured?()}
  defp required_now(grant), do: grant

  # The deployment's mounts and key names, as the modules that use them read them.
  defp names do
    transit = Application.get_env(:troupe_plane, :transit, [])

    [
      kv_mount: Application.get_env(:troupe_plane, :kms_mount, "secret"),
      transit_mount: Tokens.mount(),
      session_key: transit[:key] || "troupe-session-tokens",
      signing_key: Signing.name(),
      github_key: Key.name(),
      github_webhook_key: WebhookSecret.name()
    ]
  end

  # OpenBao answers each path as a key of `data`, and of the body itself for older clients.
  defp held(body, paths) do
    data = if is_map(body["data"]), do: body["data"], else: body
    Map.new(paths, &{&1, List.wrap(data[&1] || body[&1])})
  end

  defp policies(request) do
    case Tokens.request(:get, "/v1/auth/token/lookup-self", nil, request) do
      {:ok, %{"data" => %{"policies" => policies}}} when is_list(policies) -> policies
      _unread -> []
    end
  end

  # How a grant reaches the plane's token: its Kubernetes-auth role, or the static token
  # the deployment gave it, which is made again with the policy added.
  defp attach(config, policies) do
    if config[:token],
      do: [role: nil, policies: policies],
      else: [
        role: config[:role] || "troupe-plane",
        auth_path: config[:auth_path] || "kubernetes",
        policies: policies
      ]
  end

  defp verdict(grant, held, attach) do
    missing =
      for {pattern, wanted} <- grant.rules,
          has = Map.get(held, Policy.probe_path(pattern), []),
          "root" not in has,
          lacking = wanted -- has,
          lacking != [],
          do: %{path: pattern, capabilities: lacking}

    base = Map.take(grant, [:id, :policy, :required])

    if missing == [] do
      Map.merge(base, %{ok: true, detail: "The plane may #{grant.for}.", missing: [], fix: nil})
    else
      lacks = Enum.map_join(missing, "; ", &"#{Enum.join(&1.capabilities, ", ")} on #{&1.path}")

      Map.merge(base, %{
        ok: false,
        detail:
          "The plane's OpenBao role may not #{grant.for}, so #{grant.without}" <>
            if(grant.required, do: "", else: " (needed only for that)") <>
            ". It lacks #{lacks}.",
        missing: missing,
        fix: Policy.grant_lines(grant, attach)
      })
    end
  end

  defp unchecked(:no_kms_address, _config, _grants),
    do: {"the plane is pointed at no OpenBao (the chart's bao.address).", nil}

  defp unchecked(:no_kms_credential, config, grants) do
    auth_path = config[:auth_path] || "kubernetes"
    role = config[:role] || "troupe-plane"

    {"the plane could not log in: auth/#{auth_path} refused its ServiceAccount token for the role #{role}, or there is no such role, so nothing it does with OpenBao works.",
     Policy.plane_role_line(
       auth_path: auth_path,
       role: role,
       namespace: Application.get_env(:troupe_plane, :namespace, "troupe-system"),
       audience: Tokens.kms_audience(),
       policies: for(grant <- grants, grant.required, do: grant.policy)
     )}
  end

  defp unchecked({:unexpected_status, 403, _body}, _config, _grants),
    do:
      {"OpenBao refused the plane's look-only check (sys/capabilities-self), which the default policy allows: the plane's role is made with token_no_default_policy, or the default policy was changed.",
       nil}

  defp unchecked(reason, _config, _grants),
    do: {"OpenBao did not answer the plane's check: #{inspect(reason)}.", nil}
end
