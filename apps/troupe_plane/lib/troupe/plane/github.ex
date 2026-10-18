defmodule Troupe.Plane.GitHub do
  @moduledoc """
  The plane's GitHub App, and the short-lived installation tokens a session clones with.

  One App per plane, which the organisation registers and installs on the repositories it
  chooses (`docs/admin/github.md`). A platform admin gives the plane its id, its private
  key and the installations it may use, through `admin.github.put`; the key goes into
  OpenBao's transit engine and nothing reads it back (`Troupe.Plane.GitHub.Key`).

  ## A session names a repository, and the plane alone says how to reach it

  `session.create` takes `repository`, `"owner/name"` or `{owner, name, ref}`. It is
  checked when the session is created, against three things: the App is configured, it
  has an installation for that owner, and the session's worker profile declares the Git
  host in `egress.gitHosts` (a pod reaches nothing else). The row keeps it, and every
  activation carries it to the pod.

  The pod then asks the control channel for the session's credential (`git.credential`)
  and the plane reads the repository off the row, so a pod can ask only about a session it
  holds and only for the repository that session was created with. The answer says where
  to clone from as well as what to clone with: the URL is the plane's, built from the App's
  API URL, never one the pod or the session chose.

  ## A token is one repository's, as narrow as its use, and an hour long

  Each answer is a new installation token, asked of GitHub with the App's JWT and
  narrowed in the request to the session's one repository. The clone's is
  `contents: read`. The fix loop's (`access: :write`) carries what the session's worker
  profile grants in `spec.github.permissions` and nothing more: some of `contents`,
  `pull_requests`, `checks` and `statuses`. GitHub ends either after an hour. The pod
  holds it for the activation and asks again when the session is next activated, or when
  it is about to run out. Nothing here logs it, and the audit entry for it names the
  session, the repository, the permissions and when it expires.

  ## What a session did there

  The pod reports each step of the fix loop (`record/3`): the commit its clone started
  from, the `troupe/*` branch it pushed and its last commit there, its draft pull request,
  and each CI round on that pull request. The row keeps it (`sessions.github`), every
  listing of the session shows it, and each step is an audit entry. After the third red
  round the session's pushes are closed: the record says it stopped, and a write token is
  minted from then on with `contents: read`, so a pod could not push if it tried. The
  pull request stays a draft for a person.

  ## GitHub as the trigger

  The App's webhook secret is in transit beside its key (`GitHub.WebhookSecret`), and the
  deliveries it signs reach `POST /webhook/github` (`GitHub.Webhook`): an issue starts a run
  of a trigger on its repository (`GitHub.Issue`), and a review on a run's draft resumes
  its session (`GitHub.Review`), whose comments the plane reads here
  (`review_comments/3`).
  """

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Troupe.Plane.{Audit, Fleet, Repo}
  alias Troupe.Plane.GitHub.{App, Key, Policy, WebhookSecret}
  alias Troupe.Plane.Identity.Team
  alias Troupe.Plane.Sessions.Session

  require Logger

  @default_api "https://api.github.com"

  # What a session's clone token may do: read the repository's contents, which is what a
  # clone needs and all it needs. Metadata comes with every App token whether asked for or
  # not.
  @permissions %{"contents" => "read"}

  # What a worker profile may grant its sessions' fix-loop token, in GitHub's own names,
  # and how far each may go: the push, the draft pull request and its comments, and
  # reading CI. Nothing else: not issues, not administration, not workflows.
  @grantable %{
    "contents" => ["read", "write"],
    "pull_requests" => ["read", "write"],
    "checks" => ["read"],
    "statuses" => ["read"]
  }

  # Red CI rounds on a session's own pull request before its pushes are closed.
  @red_rounds 3

  # A commit or tree name, SHA-1 or SHA-256, as GitHub writes it.
  @object ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  # An App JWT may live ten minutes at most. Nine, issued a minute in the past, is what
  # GitHub asks for so that a clock a little ahead of its own is not refused.
  @jwt_lifetime 540
  @jwt_skew 60

  # GitHub's own rules: a login is letters, digits and single hyphens, at most 39; a
  # repository name is letters, digits, `.`, `_` and `-`, at most 100.
  @owner ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/
  @name ~r/\A[A-Za-z0-9._-]{1,100}\z/

  @doc "What a session's clone token is asked for with."
  @spec permissions() :: %{String.t() => String.t()}
  def permissions, do: @permissions

  @doc "How many red CI rounds on its own pull request close a session's pushes."
  @spec red_rounds() :: pos_integer()
  def red_rounds, do: @red_rounds

  # -- what a worker profile grants -------------------------------------------

  @doc """
  What a worker profile's `spec.github.permissions` grants its sessions' fix-loop token,
  or `contents: read` where it grants nothing: a session on it may clone and no more.
  """
  @spec grants(String.t() | nil) :: %{String.t() => String.t()}
  def grants(profile) do
    case profile && Fleet.get_profile(profile) do
      %{spec: %{"github" => %{"permissions" => %{} = granted}}} when map_size(granted) > 0 ->
        granted

      _none ->
        @permissions
    end
  end

  @doc """
  The problems with a profile's `spec.github`, as sentences, for `admin.profile.put` and a
  resource read in GitOps mode alike: an object with `permissions`, each one GitHub's name
  for a permission this may grant, at a level it may be granted; and the fix loop's policy
  (`GitHub.Policy`): `allowPublic`, `denyPaths`, `maxPushes` and `maxRuns`.
  """
  @spec spec_problems(term()) :: [String.t()]
  def spec_problems(nil), do: []

  def spec_problems(%{} = github) do
    keys = ["permissions" | Policy.profile_keys()]

    case Map.keys(github) -- keys do
      [] ->
        permission_problems(github["permissions"]) ++ Policy.profile_problems(github)

      [key | _] ->
        ["github takes #{Enum.join(keys, ", ")}, not #{key}"]
    end
  end

  def spec_problems(_other), do: ["github is an object: {permissions: {contents: write, ...}}"]

  defp permission_problems(nil), do: []

  defp permission_problems(%{} = permissions),
    do: permissions |> Enum.sort() |> Enum.flat_map(&permission_problem/1)

  defp permission_problems(_other),
    do: ["github.permissions is an object, such as {contents: write, pull_requests: write}"]

  defp permission_problem({name, level}) do
    case Map.fetch(@grantable, name) do
      {:ok, levels} ->
        if level in levels,
          do: [],
          else: [
            "github.permissions.#{name} is #{Enum.join(levels, " or ")}, not #{inspect(level)}"
          ]

      :error ->
        names = @grantable |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        ["github.permissions takes #{names}, not #{name}"]
    end
  end

  # -- the App, as an administrator reads and writes it -------------------------

  @doc """
  The App as `admin.github.get` answers it: its id, API URL and where clones come from,
  the installations, whether a key is set (its type, fingerprint and transit version,
  never the key), what a session's token is given, and who changed it last.
  """
  @spec describe() :: map()
  def describe, do: describe(stored())

  defp describe(row) do
    row = row || %App{id: App.id()}

    %{
      configured: configured?(row),
      app_id: row.app_id,
      api_url: api_url(row),
      git_url: git_url(api_url(row)),
      installations: row.installations || [],
      private_key: %{
        set: not is_nil(row.key_version),
        type: row.key_type,
        fingerprint: row.key_fingerprint,
        transit_key: Key.name(),
        version: row.key_version
      },
      # Where GitHub sends the App's events, and whether the secret it signs them with is
      # in transit: its version there, never the secret.
      webhook: %{
        path: "/webhook/github",
        secret: %{
          set: not is_nil(row.webhook_secret_version),
          transit_key: WebhookSecret.name(),
          version: row.webhook_secret_version
        }
      },
      permissions: @permissions,
      # In GitOps mode, the generation of the `GitHubApp` resource its settings were read
      # from; `nil` for an App set through the admin API.
      resource_generation: row.resource_generation,
      updated_by: row.updated_by,
      updated_at: row.updated_at
    }
  end

  @doc """
  Change the App. Only the keys sent change: `app_id` and `api_url` (`null` puts the API
  back to GitHub's own), `installations` as the whole list, `private_key` as the PEM
  GitHub downloads, and `webhook_secret` as typed into the App's webhook settings; the key
  and the secret are imported into transit and not kept anywhere else.

  Everything is checked before anything is written, the key last of all: a refusal names
  the field and says why, and leaves the App as it was. Answers the App as it was and as
  it now is.
  """
  @spec put(map(), String.t(), keyword()) ::
          {:ok, %{before: map(), now: map(), key_imported: boolean()}} | {:error, map()}
  def put(attrs, actor, opts \\ [])

  def put(attrs, actor, opts) when is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
    row = stored() || %App{id: App.id()}

    with :ok <- only(attrs),
         {:ok, changes} <- read_fields(attrs),
         {:ok, pem} <- read_key(attrs),
         {:ok, secret} <- read_webhook_secret(attrs),
         {:ok, key} <- import_key(pem, opts),
         {:ok, webhook} <- import_webhook_secret(secret, opts) do
      stored =
        row
        |> change(changes |> Map.merge(key) |> Map.merge(webhook))
        |> put_change(:updated_by, actor)
        |> Repo.insert_or_update!()

      {:ok, %{before: describe(row), now: describe(stored), key_imported: key != %{}}}
    end
  end

  def put(_attrs, _actor, _opts), do: {:error, %{field: "app", reason: "the App is an object"}}

  @fields ~w(app_id api_url installations private_key webhook_secret)

  # What a `GitHubApp` resource sets in GitOps mode: the App's settings, and not its key or
  # its webhook secret, which are only ever in transit.
  @settings ~w(app_id api_url installations)

  @doc "The keys of the App a `GitHubApp` resource holds in GitOps mode: not the key, not the secret."
  @spec settings() :: [String.t()]
  def settings, do: @settings

  @doc """
  The App's settings as a `GitHubApp` resource gives them, read as `put/3` reads them:
  `{:ok, changes}` or the field and why. Nothing is written.
  """
  @spec read_settings(map()) :: {:ok, map()} | {:error, map()}
  def read_settings(attrs) when is_map(attrs), do: attrs |> Map.take(@settings) |> read_fields()

  @doc """
  Make the App's settings what a `GitHubApp` resource says, at its generation, in GitOps
  mode: the whole of them, so a setting the resource leaves out is its default. The key and
  the webhook secret are left as they are. Answers the App as it was and as it now is.
  """
  @spec follow(map(), integer() | nil, String.t()) :: {:ok, %{before: map(), now: map()}}
  def follow(changes, generation, actor) do
    row = stored() || %App{id: App.id()}
    whole = Map.merge(%{app_id: nil, api_url: nil, installations: []}, changes)

    stored =
      row
      |> change(Map.put(whole, :resource_generation, generation))
      |> then(fn changeset ->
        if changeset.changes == %{},
          do: changeset,
          else: put_change(changeset, :updated_by, actor)
      end)
      |> Repo.insert_or_update!()

    {:ok, %{before: describe(row), now: describe(stored)}}
  end

  @doc """
  The resource the App's settings followed is gone from the cluster: they go with it, as a
  removed trigger's row does. The key and the secret stay in transit, for the App the
  repository names next.
  """
  @spec unfollow(String.t()) :: {:ok, %{before: map(), now: map()}}
  def unfollow(actor) do
    follow(%{}, nil, actor)
  end

  @doc "The keys `put/3` reads, as `admin.github.put` declares them."
  @spec keys() :: [String.t()]
  def keys, do: @fields

  @doc """
  The deliveries the App's webhook took, newest first, at most `limit`: GitHub's id for
  each, its event and action, when it came, and what the plane did with it. Never a body.
  """
  @spec deliveries(pos_integer()) :: [map()]
  def deliveries(limit) do
    from(d in Troupe.Plane.GitHub.Delivery, order_by: [desc: d.received_at], limit: ^limit)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, [:id, :event, :action, :received_at, :outcome]))
  end

  @doc """
  Forget the App: its id, API URL and installations, and its key and webhook secret, which
  are taken out of transit. Answers the App as it was, or `:not_configured` where there
  was none.

  The key goes because transit imports a new version only of the type a key already has:
  left there, it refused the next App's key wherever that was another size. The secret
  goes so that no delivery signed with it is taken again. A transit that refuses the
  deletion, a role without the policy's `delete`, leaves them where they were and says so
  in the log; the App is forgotten either way. A session that names a repository is
  refused from now on, and one that has a pod asks for a token it is not given.
  """
  @spec delete(keyword()) :: {:ok, map()} | {:error, :not_configured}
  def delete(opts \\ []) do
    case stored() do
      nil ->
        {:error, :not_configured}

      row ->
        Repo.delete!(row)
        destroy(Key, Key.name(opts), opts)
        destroy(WebhookSecret, WebhookSecret.name(opts), opts)
        {:ok, describe(row)}
    end
  end

  defp destroy(module, name, opts) do
    case module.destroy(opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "troupe plane: the GitHub App is removed, and transit kept its key #{name}: " <>
            "#{inspect(reason)}; the plane's policy needs update on #{name}/config and " <>
            "delete on the key (Troupe.KMS.Policy.github_app/3)"
        )
    end
  end

  @doc """
  Whether the App works, asked of GitHub with the App's own JWT and writing nothing: an
  App id is set, transit signs with its key, GitHub knows the App by that JWT, and every
  installation the plane was given is one GitHub lists for it. A check that cannot be
  tried because one before it failed says so. Answers `%{ok, checks, app}`, where `app`
  is GitHub's slug and name for it once GitHub has answered.
  """
  @spec check(keyword()) :: %{ok: boolean(), checks: [map()], app: map() | nil}
  def check(opts \\ []) do
    row = stored() || %App{id: App.id()}
    {checks, app} = check_steps(row, opts)
    %{ok: Enum.all?(checks, & &1.ok), checks: checks, app: app}
  end

  defp check_steps(%App{app_id: nil}, _opts) do
    {[
       result("App", false, "No App ID is set.", 0),
       not_tried("Private key", "App"),
       not_tried("GitHub", "App"),
       not_tried("Installations", "App")
     ], nil}
  end

  defp check_steps(%App{} = row, opts) do
    app_check = result("App", true, "App #{row.app_id}, at #{api_url(row)}.", 0)

    {signed, took} =
      timed(fn -> if row.key_version, do: jwt(row, opts), else: {:error, :no_key} end)

    case signed do
      {:ok, jwt} ->
        key_check =
          result(
            "Private key",
            true,
            "Transit signs with version #{row.key_version} (#{row.key_fingerprint}).",
            took
          )

        steps = ask_github(row, jwt)
        {[app_check, key_check | Enum.reject(steps, &Map.has_key?(&1, :app))], found_app(steps)}

      {:error, reason} ->
        {[
           app_check,
           result("Private key", false, explain(reason), took),
           not_tried("GitHub", "Private key"),
           not_tried("Installations", "Private key")
         ], nil}
    end
  end

  # GitHub's answer for the App and for its installations, each as a check, with the App's
  # slug and name carried beside them for the answer.
  defp ask_github(row, jwt) do
    {app, took} = timed(fn -> github_get(row, "/app", jwt) end)

    case app do
      {:ok, %{"id" => id} = body} when id == row.app_id ->
        named = %{slug: body["slug"], name: body["name"]}
        github = result("GitHub", true, "GitHub knows the App as #{body["slug"] || id}.", took)
        [github, installations_check(row, jwt), %{app: named}]

      {:ok, %{"id" => id}} ->
        [
          result("GitHub", false, "GitHub answered for App #{id}, not #{row.app_id}.", took),
          not_tried("Installations", "GitHub")
        ]

      {:error, {:github_api, _path, 401, _message}} ->
        [
          result(
            "GitHub",
            false,
            "GitHub refused the App's JWT: the key is not App #{row.app_id}'s, or the App ID is wrong.",
            took
          ),
          not_tried("Installations", "GitHub")
        ]

      {:error, reason} ->
        [result("GitHub", false, explain(reason), took), not_tried("Installations", "GitHub")]
    end
  end

  defp installations_check(%App{installations: given} = row, jwt) do
    given = given || []
    {listed, took} = timed(fn -> github_get(row, "/app/installations", jwt) end)

    case listed do
      {:ok, list} when is_list(list) ->
        known = MapSet.new(list, &{to_string(get_in(&1, ["account", "login"])), &1["id"]})
        missing = Enum.reject(given, &MapSet.member?(known, {&1["owner"], &1["installation_id"]}))

        cond do
          given == [] ->
            result(
              "Installations",
              false,
              "No installation is set, so nothing can be cloned.",
              took
            )

          missing == [] ->
            result(
              "Installations",
              true,
              "GitHub lists every installation set here: #{Enum.map_join(given, ", ", & &1["owner"])}.",
              took
            )

          true ->
            result(
              "Installations",
              false,
              "GitHub lists no installation of the App for " <>
                Enum.map_join(missing, ", ", &"#{&1["owner"]} (#{&1["installation_id"]})") <> ".",
              took
            )
        end

      {:ok, _other} ->
        result("Installations", false, "GitHub's answer was not a list of installations.", took)

      {:error, reason} ->
        result("Installations", false, explain(reason), took)
    end
  end

  defp found_app(steps), do: Enum.find_value(steps, &Map.get(&1, :app))

  defp not_tried(name, after_check),
    do: result(name, false, "Not tried: #{after_check} did not pass.", 0)

  defp result(name, ok, detail, took), do: %{name: name, ok: ok, detail: detail, took_ms: took}

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    answer = fun.()
    {answer, System.monotonic_time(:millisecond) - started}
  end

  # A read of GitHub's App API as the App: the JWT in the header and nowhere else.
  defp github_get(row, path, jwt) do
    url = api_url(row) <> path

    case Req.request(
           method: :get,
           url: url,
           headers: [
             {"authorization", "Bearer " <> jwt},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"},
             {"user-agent", "troupe-plane"}
           ],
           redirect: false,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:github_api, path, status, message(body)}}
      {:error, %{reason: reason}} -> {:error, {:github_unreachable, URI.parse(url).host, reason}}
      {:error, reason} -> {:error, {:github_unreachable, URI.parse(url).host, reason}}
    end
  end

  defp only(attrs) do
    case Map.keys(attrs) -- @fields do
      [] ->
        :ok

      unknown ->
        {:error, %{field: hd(unknown), reason: "the App takes #{Enum.join(@fields, ", ")}"}}
    end
  end

  # The keys sent, each read; a key not sent is not a change.
  defp read_fields(attrs) do
    ~w(app_id api_url installations)
    |> Enum.filter(&Map.has_key?(attrs, &1))
    |> Enum.reduce_while({:ok, %{}}, fn field, {:ok, acc} ->
      case field(field, attrs[field]) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(field), value)}}
        {:error, reason} -> {:halt, {:error, %{field: field, reason: reason}}}
      end
    end)
  end

  defp field("app_id", nil), do: {:ok, nil}
  defp field("app_id", id) when is_integer(id) and id > 0, do: {:ok, id}

  defp field("app_id", id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, "the App ID is the number GitHub shows on the App's page"}
    end
  end

  defp field("app_id", _id),
    do: {:error, "the App ID is the number GitHub shows on the App's page"}

  defp field("api_url", nil), do: {:ok, nil}
  defp field("api_url", ""), do: {:ok, nil}

  defp field("api_url", url) when is_binary(url) do
    url = String.trim_trailing(url, "/")

    case git_url(url) do
      nil ->
        {:error,
         "an API URL is https://api.github.com, a GitHub Enterprise Cloud " <>
           "https://api.<name>.ghe.com, or a GitHub Enterprise Server's https://<host>/api/v3"}

      _git ->
        {:ok, url}
    end
  end

  defp field("api_url", _url), do: {:error, "the API URL is a URL"}

  defp field("installations", nil), do: {:ok, []}

  defp field("installations", list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case installation(entry) do
        {:ok, read} -> {:cont, {:ok, [read | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, read} ->
        read = Enum.reverse(read)
        owners = Enum.map(read, &String.downcase(&1["owner"]))

        if length(Enum.uniq(owners)) == length(owners),
          do: {:ok, read},
          else: {:error, "each owner has one installation; one is listed twice"}

      error ->
        error
    end
  end

  defp field("installations", _list),
    do: {:error, "installations are a list of {owner, installation_id}"}

  defp installation(%{} = entry) do
    entry = Map.new(entry, fn {key, value} -> {to_string(key), value} end)

    with {:ok, owner} <- owner(entry["owner"]),
         {:ok, id} <- installation_id(entry["installation_id"]) do
      {:ok, %{"owner" => owner, "installation_id" => id}}
    end
  end

  defp installation(_entry), do: {:error, "an installation is {owner, installation_id}"}

  defp owner(owner) when is_binary(owner) do
    if Regex.match?(@owner, owner),
      do: {:ok, owner},
      else: {:error, "#{inspect(owner)} is not a GitHub organisation or account name"}
  end

  defp owner(_owner), do: {:error, "an installation names its owner, the organisation or account"}

  defp installation_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp installation_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, "an installation_id is the number in the installation's settings URL"}
    end
  end

  defp installation_id(_id),
    do: {:error, "an installation_id is the number in the installation's settings URL"}

  defp read_key(%{"private_key" => pem}) when is_binary(pem) and pem != "" do
    case Key.read(pem) do
      {:ok, _known} -> {:ok, pem}
      {:error, reason} -> {:error, %{field: "private_key", reason: reason}}
    end
  end

  # Blank leaves the key as it is: there is no clearing one from here, since an App with no
  # key is an App nobody can use, and an App id or installations cleared says that better.
  defp read_key(%{"private_key" => blank}) when blank in [nil, ""], do: {:ok, nil}

  defp read_key(%{"private_key" => _other}),
    do:
      {:error,
       %{field: "private_key", reason: "the private key is the PEM text GitHub downloads"}}

  defp read_key(_attrs), do: {:ok, nil}

  defp import_key(nil, _opts), do: {:ok, %{}}

  defp import_key(pem, opts) do
    case Key.import(pem, opts) do
      {:ok, key} ->
        {:ok, %{key_type: key.type, key_fingerprint: key.fingerprint, key_version: key.version}}

      {:error, reason} ->
        {:error,
         %{field: "private_key", reason: "OpenBao did not take the key: #{explain(reason)}"}}
    end
  end

  # The webhook secret as the App's settings on GitHub have it. Blank leaves it as it is,
  # as a blank key does; the webhook is turned off on GitHub.
  defp read_webhook_secret(%{"webhook_secret" => secret}) when secret in [nil, ""],
    do: {:ok, nil}

  defp read_webhook_secret(%{"webhook_secret" => secret}) do
    case WebhookSecret.read(secret) do
      :ok -> {:ok, secret}
      {:error, reason} -> {:error, %{field: "webhook_secret", reason: reason}}
    end
  end

  defp read_webhook_secret(_attrs), do: {:ok, nil}

  defp import_webhook_secret(nil, _opts), do: {:ok, %{}}

  defp import_webhook_secret(secret, opts) do
    case WebhookSecret.import(secret, opts) do
      {:ok, version} ->
        {:ok, %{webhook_secret_version: version}}

      {:error, reason} ->
        {:error,
         %{field: "webhook_secret", reason: "OpenBao did not take the secret: #{explain(reason)}"}}
    end
  end

  @doc "The App's row, or `nil` where there is none or it could not be read."
  @spec app() :: App.t() | nil
  def app, do: stored()

  defp stored do
    Repo.get(App, App.id())
  rescue
    error ->
      Logger.warning("troupe plane: could not read the GitHub App: #{inspect(error)}")
      nil
  catch
    :exit, reason ->
      Logger.warning("troupe plane: could not read the GitHub App: #{inspect(reason)}")
      nil
  end

  defp configured?(row) do
    not is_nil(row.app_id) and not is_nil(row.key_version) and (row.installations || []) != []
  end

  # -- where GitHub is --------------------------------------------------------

  defp api_url(%App{api_url: nil}), do: @default_api
  defp api_url(%App{api_url: url}), do: url

  @doc """
  Where clones come from, for an API URL: `https://github.com` for GitHub's own,
  `https://<name>.ghe.com` for Enterprise Cloud, the server itself for Enterprise Server
  (whose API is under `/api/v3`). `nil` for a URL that is none of them. Plain HTTP is
  taken only for a loopback address, which is a stand-in's.
  """
  @spec git_url(String.t()) :: String.t() | nil
  def git_url(api_url) do
    with %URI{scheme: scheme, host: host, port: port, path: path} when is_binary(host) <-
           URI.parse(api_url),
         true <- scheme == "https" or (scheme == "http" and loopback?(host)),
         {:ok, git_host} <- git_host(host, path || "") do
      URI.to_string(%URI{scheme: scheme, host: git_host, port: port})
    else
      _ -> nil
    end
  end

  defp git_host("api." <> rest, path) when path in ["", "/"] and rest != "", do: {:ok, rest}
  defp git_host(host, path) when path in ["/api/v3", "/api/v3/"], do: {:ok, host}
  defp git_host(_host, _path), do: :error

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  @doc "The host a session's pod clones from, which its profile must declare in `egress.gitHosts`."
  @spec git_host() :: String.t() | nil
  def git_host do
    case stored() |> then(&(&1 || %App{})) |> api_url() |> git_url() do
      nil -> nil
      url -> URI.parse(url).host
    end
  end

  # -- a session's repository -------------------------------------------------

  @doc """
  Read `session.create`'s `repository` for a session of `team` on `profile`:
  `"owner/name"` or `{owner, name, ref}`. Answers what the row keeps, `nil` for none, or
  why it will not do, as a sentence: no App here, no installation for that owner, a team
  that does not list it, or a profile that does not declare the Git host.
  """
  @spec repository(term(), String.t() | nil, Team.t() | nil) ::
          {:ok, map() | nil} | {:error, String.t()}
  def repository(given, profile, team)

  def repository(nil, _profile, _team), do: {:ok, nil}

  def repository(text, profile, team) when is_binary(text) do
    case String.split(text, "/") do
      [owner, name] -> repository(%{"owner" => owner, "name" => name}, profile, team)
      _ -> {:error, "a repository is owner/name, or {owner, name, ref}"}
    end
  end

  def repository(%{} = given, profile, team) do
    given = Map.new(given, fn {key, value} -> {to_string(key), value} end)

    with :ok <- only_repository_keys(given),
         {:ok, owner} <- owner(given["owner"]),
         {:ok, name} <- name(given["name"]),
         {:ok, ref} <- ref(given["ref"]),
         {:ok, app} <- configured(),
         {:ok, _installation} <- installation_for(app, owner),
         :ok <- Policy.listed(team, owner, name),
         :ok <- reachable(profile, app) do
      {:ok, %{"owner" => owner, "name" => name, "ref" => ref}}
    else
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  def repository(_other, _profile, _team),
    do: {:error, "a repository is owner/name, or {owner, name, ref}"}

  defp only_repository_keys(given) do
    case Map.keys(given) -- ~w(owner name ref) do
      [] -> :ok
      _ -> {:error, "a repository takes owner, name and ref"}
    end
  end

  defp name(name) when is_binary(name) do
    if Regex.match?(@name, name) and name not in [".", ".."] and
         not String.ends_with?(name, ".git"),
       do: {:ok, name},
       else: {:error, "#{inspect(name)} is not a repository name"}
  end

  defp name(_name), do: {:error, "a repository names its owner and its name"}

  # A branch or tag to clone, as git would take it on a command line, and nothing that
  # could be read as an option or climb out of `refs/`.
  defp ref(nil), do: {:ok, nil}

  defp ref(ref) when is_binary(ref) do
    valid =
      Regex.match?(~r/\A[A-Za-z0-9._\/-]{1,200}\z/, ref) and
        not String.starts_with?(ref, ["-", "/", "."]) and
        not String.ends_with?(ref, ["/", ".", ".lock"]) and
        not String.contains?(ref, ["..", "//", "/."])

    if valid, do: {:ok, ref}, else: {:error, "#{inspect(ref)} is not a branch or tag name"}
  end

  defp ref(_ref), do: {:error, "a ref is a branch or tag name"}

  defp configured do
    case stored() do
      %App{} = app -> if configured?(app), do: {:ok, app}, else: {:error, :not_configured}
      nil -> {:error, :not_configured}
    end
  end

  defp installation_for(%App{installations: installations}, owner) do
    case Enum.find(installations || [], &(String.downcase(&1["owner"]) == String.downcase(owner))) do
      nil -> {:error, {:not_installed, owner, Enum.map(installations || [], & &1["owner"])}}
      installation -> {:ok, installation}
    end
  end

  @doc """
  Whether a delivery that names this owner and installation is about one of this plane's
  installations: the App is configured here, and the installation it lists for the owner
  is the one the delivery names.
  """
  @spec installed?(term(), term()) :: boolean()
  def installed?(owner, installation_id) when is_binary(owner) and is_integer(installation_id) do
    with {:ok, app} <- configured(),
         {:ok, installation} <- installation_for(app, owner) do
      installation["installation_id"] == installation_id
    else
      _ -> false
    end
  end

  def installed?(_owner, _installation_id), do: false

  # A pod reaches the hosts its profile declares and no others, so a repository on a host
  # the profile does not name is refused here rather than left to time out on the pod.
  defp reachable(profile, app) do
    host = app |> api_url() |> git_url() |> URI.parse() |> Map.get(:host)

    if Enum.any?(declared(profile), &Troupe.Policy.matches?(host, &1)),
      do: :ok,
      else: {:error, {:host_not_declared, profile, host}}
  end

  defp declared(profile) do
    case profile && Fleet.get_profile(profile) do
      %{spec: spec} when is_map(spec) -> get_in(spec, ["egress", "gitHosts"]) || []
      _ -> []
    end
  end

  # -- a session's token ------------------------------------------------------

  @doc """
  A new installation token for a session's repository, and where to clone it from:
  `{token, expires_at, url, host, username, ref, repository, installation_id,
  permissions, api_url}`, the API URL being where the token is revoked and where the fix
  loop's calls go. With `access: :write`, `policy` too: what the pod checks before a push
  or a pull request (`GitHub.Policy.for_session/1`).

  Asked of GitHub every time, narrowed to the one repository. `access: :read` (the
  default) is the clone's, `permissions/0`; `access: :write` is the fix loop's, what the
  session's profile grants (`grants/1`), refused where that is reading alone, and with
  `contents: read` once the session's pushes are closed or it has made as many as its
  caps allow. The checks `repository/3` made at creation are made again, since the App,
  its installations, the team's repositories and the profile may all have changed since;
  a write token also needs the profile to declare the API's host.
  """
  @spec credential(Session.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def credential(session, opts \\ [])

  def credential(
        %Session{repository: %{"owner" => owner, "name" => name} = repository} = session,
        opts
      ) do
    access = Keyword.get(opts, :access, :read)

    with {:ok, app} <- configured(),
         {:ok, installation} <- installation_for(app, owner),
         :ok <- Policy.listed(Policy.team_of(session), owner, name),
         :ok <- reachable(session.profile, app),
         {:ok, permissions} <- permissions_for(access, session),
         :ok <- api_reachable(access, session.profile, app),
         {:ok, jwt} <- jwt(app, opts),
         {:ok, token, expires_at} <- exchange(app, installation, name, permissions, jwt) do
      git = git_url(api_url(app))

      credential = %{
        "token" => token,
        "expires_at" => expires_at,
        "url" => "#{git}/#{owner}/#{name}.git",
        "host" => URI.parse(git).host,
        "username" => "x-access-token",
        "ref" => repository["ref"],
        "repository" => "#{owner}/#{name}",
        "installation_id" => installation["installation_id"],
        "permissions" => permissions,
        "api_url" => api_url(app)
      }

      {:ok,
       if(access == :write,
         do: Map.put(credential, "policy", Policy.for_session(session)),
         else: credential
       )}
    end
  end

  def credential(%Session{}, _opts), do: {:error, :no_repository}

  # The clone's is read-only whatever the profile says. The fix loop's is the profile's
  # grant, and only where it grants something to write with; once three red rounds or its
  # cap of pushes have closed the session's pushes, it still comments and reads CI, and can
  # no longer push.
  defp permissions_for(:read, _session), do: {:ok, @permissions}

  defp permissions_for(:write, %Session{} = session) do
    granted = grants(session.profile)

    cond do
      "write" not in Map.values(granted) -> {:error, {:no_write, session.profile}}
      stopped?(session.github) -> {:ok, Map.put(granted, "contents", "read")}
      Policy.pushes_spent?(session, session.github) -> {:ok, Map.put(granted, "contents", "read")}
      true -> {:ok, granted}
    end
  end

  defp permissions_for(other, _session), do: {:error, {:access, other}}

  # The fix loop's calls go to the API from the pod, so a profile whose sessions make them
  # declares the API's host as well as the Git host: `api.github.com` beside `github.com`.
  # An Enterprise Server has both on one host, which `reachable/2` has checked already.
  defp api_reachable(:write, profile, app) do
    host = app |> api_url() |> URI.parse() |> Map.get(:host)

    if Enum.any?(declared(profile), &Troupe.Policy.matches?(host, &1)),
      do: :ok,
      else: {:error, {:api_not_declared, profile, host}}
  end

  defp api_reachable(_access, _profile, _app), do: :ok

  @doc """
  The App's JWT: `iss` the App id, issued a minute ago, nine minutes to live, signed RS256
  with the key in transit.
  """
  @spec jwt(App.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def jwt(%App{app_id: app_id}, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    header = %{"alg" => "RS256", "typ" => "JWT"}
    payload = %{"iat" => now - @jwt_skew, "exp" => now + @jwt_lifetime, "iss" => app_id}
    input = segment(header) <> "." <> segment(payload)

    with {:ok, signature} <- Key.sign(input, opts), do: {:ok, input <> "." <> signature}
  end

  defp segment(map), do: map |> Jason.encode!() |> Base.url_encode64(padding: false)

  # The token is in the answer and nowhere else: not in an error, which names GitHub's
  # status and message, and not in a log line.
  defp exchange(app, installation, name, permissions, jwt) do
    url = "#{api_url(app)}/app/installations/#{installation["installation_id"]}/access_tokens"

    case Req.request(
           method: :post,
           url: url,
           json: %{"repositories" => [name], "permissions" => permissions},
           headers: [
             {"authorization", "Bearer " <> jwt},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"},
             {"user-agent", "troupe-plane"}
           ],
           redirect: false,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 201, body: %{"token" => token, "expires_at" => expires_at}}}
      when is_binary(token) ->
        {:ok, token, expires_at}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github, status, message(body), installation["owner"], name}}

      {:error, %{reason: reason}} ->
        {:error, {:github_unreachable, URI.parse(url).host, reason}}

      {:error, reason} ->
        {:error, {:github_unreachable, URI.parse(url).host, reason}}
    end
  end

  defp message(%{"message" => message}) when is_binary(message), do: message
  defp message(_body), do: nil

  # -- a review on a session's pull request -------------------------------------

  # The most of a review's comments the plane reads: one page, which is more than a review
  # that a session could take in one turn.
  @review_comments 50

  @doc """
  The comments of one review on a session's pull request, oldest first, each
  `{path, line, body, author}`: what a review that resumes the session says beside its
  body. Read by the plane with a token of its own, narrowed to the session's repository and
  `pull_requests: read`, an hour long and audited as `github.token` for the session's
  owner; the token is used for this one request and kept nowhere.
  """
  @spec review_comments(Session.t(), pos_integer(), pos_integer()) ::
          {:ok, [map()]} | {:error, term()}
  def review_comments(
        %Session{repository: %{"owner" => owner, "name" => name}} = session,
        number,
        review_id
      )
      when is_integer(number) and is_integer(review_id) do
    permissions = %{"pull_requests" => "read"}

    audit = %{
      "session_id" => session.id,
      "for" => "review #{review_id} on pull request #{number}"
    }

    with {:ok, reader} <- reader(owner, name, permissions, audit, session.owner_subject),
         {:ok, comments} when is_list(comments) <-
           reader.get.("/pulls/#{number}/reviews/#{review_id}/comments",
             per_page: @review_comments
           ) do
      {:ok, Enum.map(comments, &review_comment/1)}
    else
      {:ok, _other} -> {:error, {:github, 200, "not a list of comments", owner, name}}
      {:error, reason} -> {:error, reason}
    end
  end

  def review_comments(%Session{}, _number, _review_id), do: {:error, :no_repository}

  # -- the plane's own reads of a repository ---------------------------------------

  @typedoc """
  The plane's reads of one repository, with one token: `get` of a path under
  `/repos/<owner>/<name>` (`""` for the repository itself) and its query, and `search` of
  its open issues for a query, at most a number of them, oldest first.
  """
  @type reader :: %{
          repository: String.t(),
          get: (String.t(), keyword() -> {:ok, term()} | {:error, term()}),
          search: (String.t(), pos_integer() -> {:ok, [map()]} | {:error, term()})
        }

  @doc """
  The plane's own reads of one repository, with a token of its own: narrowed in the request
  to the repository and `permissions`, an hour long, used for the reads the caller makes and
  kept nowhere, and audited as `github.token` with `audit`'s detail for `on_behalf_of`.

  What a review's comments, the pull request a comment is on, and a sweep's or a person's
  issues are read with. The App, its installation for the owner, and GitHub's answer are
  the checks; whether a team may name the repository is the caller's.
  """
  @spec reader(String.t(), String.t(), map(), map(), String.t() | nil) ::
          {:ok, reader()} | {:error, term()}
  def reader(owner, name, permissions, audit, on_behalf_of) do
    with {:ok, app} <- configured(),
         {:ok, installation} <- installation_for(app, owner),
         {:ok, jwt} <- jwt(app),
         {:ok, token, expires_at} <- exchange(app, installation, name, permissions, jwt) do
      {:ok, _} =
        Audit.record(
          "github",
          "github.token",
          "#{owner}/#{name}",
          Map.merge(audit, %{"permissions" => permissions, "expires_at" => expires_at}),
          on_behalf_of: on_behalf_of
        )

      base = "#{api_url(app)}/repos/#{owner}/#{name}"

      {:ok,
       %{
         repository: "#{owner}/#{name}",
         get: fn path, params -> read(base <> path, params, token, owner, name) end,
         search: fn query, limit -> search(app, token, owner, name, query, limit) end
       }}
    end
  end

  # GitHub's issue search, with the repository and `is:issue is:open` the plane's and the
  # rest the trigger's query.
  defp search(app, token, owner, name, query, limit) do
    q = "repo:#{owner}/#{name} is:issue is:open #{query}"
    params = [q: q, sort: "created", order: "asc", per_page: limit]

    case read("#{api_url(app)}/search/issues", params, token, owner, name) do
      {:ok, %{"items" => items}} when is_list(items) ->
        # The token reaches this one repository and the qualifiers are the plane's; an item
        # of another repository is still not one of this one's issues.
        {:ok, Enum.filter(items, &of_repository?(&1, owner, name))}

      {:ok, _other} ->
        {:error, {:github, 200, "not a search answer", owner, name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp of_repository?(%{"repository_url" => url}, owner, name) when is_binary(url),
    do: String.ends_with?(String.downcase(url), String.downcase("/repos/#{owner}/#{name}"))

  defp of_repository?(_item, _owner, _name), do: false

  # A read with a token, in the header and nowhere else: not in an error, which names
  # GitHub's status and message.
  defp read(url, params, token, owner, name) do
    case Req.request(
           method: :get,
           url: url,
           params: params,
           headers: [
             {"authorization", "Bearer " <> token},
             {"accept", "application/vnd.github+json"},
             {"x-github-api-version", "2022-11-28"},
             {"user-agent", "troupe-plane"}
           ],
           redirect: false,
           retry: false,
           receive_timeout: 15_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:github, status, message(body), owner, name}}

      {:error, reason} ->
        {:error, {:github_unreachable, URI.parse(url).host, reason}}
    end
  end

  defp review_comment(comment) when is_map(comment) do
    %{
      "path" => comment["path"],
      "line" => comment["line"] || comment["original_line"],
      "body" => comment["body"],
      "author" => get_in(comment, ["user", "login"])
    }
  end

  defp review_comment(_other), do: %{"body" => nil}

  # -- what a session did there -----------------------------------------------

  @doc """
  Record a step of a session's fix loop, as the pod that holds it reports it, and answer
  the record as it now is: `{github, stopped_now}`.

  `changes` has one or more of:

  - `base`: the commit the session's clone started from, once;
  - `push`: `{branch, commit, tree}`, a commit the session pushed. The branch is under
    `troupe/` and is the session's one branch: the first push names it and every later one
    is refused another. None once the session has stopped;
  - `pull_request`: `{number, url}`, its draft pull request, once, after a push; the URL is
    this repository's pull request on the App's host and no other;
  - `round`: `{commit, state, failing}`, the CI of its last push on that pull request,
    `red` or `green` with the names of the checks that failed, once a commit. The third red
    one stops the session: `stopped` says when and why, and `stopped_now` is true in the
    answer that did it;
  - `stop`: `{reason: "pushes"}`, the pod saying the run asked for a push past its cap of
    pushes (`GitHub.Policy.max_pushes/1`). Taken only once the record has that many; it
    stops the session as the third red round does. A push past the cap is refused here
    whether or not the pod says so.

  Checked whole before anything is written, under the row's lock, so two reports at once
  cannot both be the first push or both miss the third red round. Each step is an audit
  entry by `actor` for the session's owner. Metadata only: a commit message, a pull
  request's text or CI's output is never sent here.
  """
  @spec record(Session.t(), map(), String.t()) ::
          {:ok, %{github: map(), stopped_now: boolean()}} | {:error, term()}
  def record(%Session{repository: %{}} = session, changes, actor) when is_map(changes) do
    Repo.transaction(fn ->
      locked =
        Repo.one!(from(s in Session, where: s.id == ^session.id, lock: "FOR UPDATE"))

      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      case apply_changes(locked.github || %{}, changes, locked, now) do
        {:ok, github, steps} -> keep(locked, github, steps, actor)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def record(%Session{}, _changes, _actor), do: {:error, :no_repository}

  defp keep(session, github, steps, actor) do
    if github != (session.github || %{}), do: session |> change(github: github) |> Repo.update!()
    Enum.each(steps, &audit(&1, session, actor))
    %{github: github, stopped_now: Enum.any?(steps, &match?({:stopped, _}, &1))}
  end

  @doc "Whether a session's record says its pushes are closed."
  @spec stopped?(map() | nil) :: boolean()
  def stopped?(%{"stopped" => %{}}), do: true
  def stopped?(_github), do: false

  @changes ~w(base push pull_request round stop)

  # In a fixed order, so a report of a push and its round together applies the push first.
  defp apply_changes(record, changes, session, now) do
    case Map.keys(changes) -- @changes do
      [] ->
        @changes
        |> Enum.filter(&Map.has_key?(changes, &1))
        |> Enum.reduce_while({:ok, record, []}, fn key, {:ok, acc, steps} ->
          step(change_record(key, changes[key], acc, session, now), steps)
        end)

      [unknown | _] ->
        {:error, "a record takes #{Enum.join(@changes, ", ")}, not #{unknown}"}
    end
  end

  defp step({:ok, record, more}, steps), do: {:cont, {:ok, record, steps ++ more}}
  defp step({:error, reason}, _steps), do: {:halt, {:error, reason}}

  defp change_record("base", base, record, _session, _now) do
    cond do
      not object?(base) -> {:error, "base is a commit name"}
      record["base"] in [nil, base] -> {:ok, Map.put(record, "base", base), []}
      true -> {:error, "the session's starting commit is recorded already"}
    end
  end

  defp change_record("push", %{} = push, record, session, now) do
    branch = push["branch"]

    cond do
      stopped?(record) ->
        {:error, "this session's pushes are closed (#{record["stopped"]["reason"]})"}

      Policy.pushes_spent?(session, record) ->
        {:error,
         "this run has made #{record["pushes"]} pushes, as many as its cap of " <>
           "#{Policy.max_pushes(session)} allows"}

      not troupe_branch?(branch) ->
        {:error, "a session pushes only to a branch under troupe/, not #{inspect(branch)}"}

      record["branch"] not in [nil, branch] ->
        {:error, "this session pushes to #{record["branch"]} and no other branch"}

      not (object?(push["commit"]) and object?(push["tree"])) ->
        {:error, "a push names its commit and its tree"}

      true ->
        {:ok,
         Map.merge(record, %{
           "branch" => branch,
           "commit" => push["commit"],
           "tree" => push["tree"],
           "pushed_at" => now,
           "pushes" => (record["pushes"] || 0) + 1
         }), [{:push, %{"branch" => branch, "commit" => push["commit"]}}]}
    end
  end

  defp change_record("pull_request", %{"number" => number, "url" => url}, record, session, _now)
       when is_integer(number) and number > 0 and is_binary(url) do
    pull_request = %{"number" => number, "url" => url}

    cond do
      is_nil(record["branch"]) ->
        {:error, "a pull request comes after the session's first push"}

      String.downcase(url) != String.downcase(pull_request_url(session, number)) ->
        {:error, "a pull request's URL is the session's repository's, on the App's host"}

      record["pull_request"] == pull_request ->
        {:ok, record, []}

      is_nil(record["pull_request"]) ->
        {:ok, Map.put(record, "pull_request", pull_request), [{:pull_request, pull_request}]}

      true ->
        {:error, "this session has its pull request already"}
    end
  end

  defp change_record(
         "round",
         %{"commit" => commit, "state" => state} = round,
         record,
         _session,
         now
       )
       when state in ["red", "green"] do
    rounds = record["rounds"] || []

    cond do
      is_nil(record["pull_request"]) ->
        {:error, "a CI round is one on the session's pull request, and it has none"}

      commit != record["commit"] ->
        {:error, "a CI round is the session's last push's"}

      Enum.any?(rounds, &(&1["commit"] == commit)) ->
        {:ok, record, []}

      true ->
        entry = %{"commit" => commit, "state" => state, "failing" => failing(round), "at" => now}
        record = Map.put(record, "rounds", rounds ++ [entry])
        red = Enum.count(record["rounds"], &(&1["state"] == "red"))

        if red >= @red_rounds and not stopped?(record) do
          stopped = %{"at" => now, "reason" => "#{@red_rounds} red CI rounds"}
          {:ok, Map.put(record, "stopped", stopped), [{:round, entry}, {:stopped, stopped}]}
        else
          {:ok, record, [{:round, entry}]}
        end
    end
  end

  defp change_record("stop", %{"reason" => "pushes"}, record, session, now) do
    cond do
      stopped?(record) ->
        {:ok, record, []}

      Policy.pushes_spent?(session, record) ->
        cap = Policy.max_pushes(session)

        stopped = %{
          "at" => now,
          "reason" => "its cap of #{cap} #{plural(cap, "push", "pushes")}",
          "cap" => "pushes"
        }

        {:ok, Map.put(record, "stopped", stopped), [{:stopped, stopped}]}

      true ->
        {:error, "this run has pushes left under its cap, so nothing stops it"}
    end
  end

  defp change_record(key, _value, _record, _session, _now),
    do: {:error, "#{key} is not one this takes in that shape"}

  defp plural(1, one, _many), do: one
  defp plural(_n, _one, many), do: many

  # The checks that failed, by name: what a person reading the run sees first. Bounded,
  # since the names are the repository's CI's to choose.
  defp failing(%{"failing" => names}) when is_list(names) do
    names
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.slice(&1, 0, 100))
    |> Enum.take(20)
  end

  defp failing(_round), do: []

  defp pull_request_url(%Session{repository: %{"owner" => owner, "name" => name}}, number) do
    git = (stored() || %App{}) |> api_url() |> git_url()
    "#{git}/#{owner}/#{name}/pull/#{number}"
  end

  defp object?(name), do: is_binary(name) and Regex.match?(@object, name)

  @doc """
  Whether `branch` is one a session may push: under `troupe/`, and a name git takes as a
  branch, with nothing that could be read as an option or climb out of `refs/heads/`.
  """
  @spec troupe_branch?(term()) :: boolean()
  def troupe_branch?("troupe/" <> rest = branch) when rest != "" do
    match?({:ok, _}, ref(branch)) and not String.contains?(branch, "@{")
  end

  def troupe_branch?(_branch), do: false

  defp audit({step, data}, session, actor) do
    {:ok, _} =
      Audit.record(
        actor,
        "github.#{step}",
        "#{session.repository["owner"]}/#{session.repository["name"]}",
        Map.put(data, "session_id", session.id),
        on_behalf_of: session.owner_subject
      )
  end

  # -- saying why ---------------------------------------------------------------

  @doc "Why a repository or a token could not be had, as a sentence."
  @spec explain(term()) :: String.t()
  def explain(reason) when is_binary(reason), do: reason

  def explain(:not_configured),
    do:
      "this plane has no GitHub App yet: a platform admin gives it one with admin.github.put " <>
        "(an App ID, its private key and at least one installation)"

  def explain({:not_installed, owner, []}),
    do: "the GitHub App has no installations here, so it cannot reach #{owner}"

  def explain({:not_installed, owner, owners}),
    do:
      "the GitHub App is not installed for #{owner} on this plane; it is for " <>
        Enum.join(owners, ", ")

  def explain({:no_team, full}),
    do:
      "a session names a repository through a team that lists it, and this one has no team, " <>
        "so it cannot name #{full}"

  def explain({:not_listed, team, full, []}),
    do:
      "the team #{team} lists no GitHub repositories, so its sessions name none: a team " <>
        "admin adds #{full} to the team's github.repositories"

  def explain({:not_listed, team, full, _listed}),
    do:
      "the team #{team} does not list #{full} among the GitHub repositories its sessions " <>
        "may name: a team admin adds it to the team's github.repositories"

  def explain({:host_not_declared, profile, host}),
    do:
      "the worker profile #{profile || "(none)"} does not declare #{host} in egress.gitHosts, " <>
        "so its pods cannot reach it"

  def explain({:api_not_declared, profile, host}),
    do:
      "the worker profile #{profile || "(none)"} does not declare #{host}, where GitHub's API " <>
        "is, in egress.gitHosts, so its pods cannot push or open a pull request"

  def explain({:no_write, profile}),
    do:
      "the worker profile #{profile || "(none)"} grants GitHub nothing to write with " <>
        "(spec.github.permissions), so its sessions clone and do no more"

  def explain({:access, access}), do: "#{inspect(access)} is not read or write"

  def explain(:no_repository), do: "the session names no repository"
  def explain(:no_key), do: "the App's private key is not in OpenBao"
  def explain(:no_secret), do: "the App's webhook secret is not in OpenBao"

  def explain({:github, 401, message, _owner, _name}),
    do:
      "GitHub refused the App's JWT (#{message || "401"}): the App ID is wrong, or the key " <>
        "in OpenBao is not one GitHub has for the App"

  def explain({:github, 404, _message, owner, _name}),
    do:
      "GitHub has no such installation for #{owner}: the installation_id is wrong, or the App was uninstalled"

  def explain({:github, 422, message, owner, name}),
    do:
      "GitHub would not narrow a token to #{owner}/#{name} (#{message || "422"}): the " <>
        "installation does not include that repository, or the App has not been granted a " <>
        "permission asked for"

  def explain({:github, status, message, _owner, _name}),
    do: "GitHub answered #{status}#{if message, do: " (#{message})"}"

  def explain({:github_api, path, 404, _message}),
    do: "GitHub has no #{path} here: the API URL is not a GitHub API's"

  def explain({:github_api, path, status, message}),
    do: "GitHub answered #{status} for #{path}#{if message, do: " (#{message})"}"

  def explain({:github_unreachable, host, reason}),
    do: "GitHub at #{host} could not be reached: #{inspect(reason)}"

  def explain({:key_type, there, given}),
    do: "transit holds the App's key as #{there}, and this one is #{given}"

  def explain({:unexpected_status, status, body}),
    do: "OpenBao answered #{status}: #{inspect(errors(body))}"

  def explain(:no_kms_address), do: "this plane has no OpenBao configured"
  def explain(:no_kms_credential), do: "this plane has no OpenBao credential"
  def explain(other), do: inspect(other)

  defp errors(%{"errors" => errors}), do: errors
  defp errors(body), do: body
end
