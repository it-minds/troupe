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

  ## A token is one repository's, read-only, and an hour long

  Each answer is a new installation token, asked of GitHub with the App's JWT and
  narrowed in the request to the session's one repository and `contents: read`. GitHub
  ends it after an hour. The pod holds it for the activation and asks again when the
  session is next activated, or when it is about to run out. Nothing here logs it, and
  the audit entry for it names the session, the repository and when it expires.
  """

  import Ecto.Changeset

  alias Troupe.Plane.{Fleet, Repo}
  alias Troupe.Plane.GitHub.{App, Key}
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Policy

  require Logger

  @default_api "https://api.github.com"

  # What a session's token may do: read the repository's contents, which is what a clone
  # needs and all it needs. Metadata comes with every App token whether asked for or not.
  @permissions %{"contents" => "read"}

  # An App JWT may live ten minutes at most. Nine, issued a minute in the past, is what
  # GitHub asks for so that a clock a little ahead of its own is not refused.
  @jwt_lifetime 540
  @jwt_skew 60

  # GitHub's own rules: a login is letters, digits and single hyphens, at most 39; a
  # repository name is letters, digits, `.`, `_` and `-`, at most 100.
  @owner ~r/\A[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}\z/
  @name ~r/\A[A-Za-z0-9._-]{1,100}\z/

  @doc "What a session's installation token is asked for with."
  @spec permissions() :: %{String.t() => String.t()}
  def permissions, do: @permissions

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
      permissions: @permissions,
      updated_by: row.updated_by,
      updated_at: row.updated_at
    }
  end

  @doc """
  Change the App. Only the keys sent change: `app_id` and `api_url` (`null` puts the API
  back to GitHub's own), `installations` as the whole list, and `private_key` as the PEM
  GitHub downloads, which is imported into transit and not kept anywhere else.

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
         {:ok, key} <- import_key(pem, opts) do
      stored =
        row
        |> change(Map.merge(changes, key))
        |> put_change(:updated_by, actor)
        |> Repo.insert_or_update!()

      {:ok, %{before: describe(row), now: describe(stored), key_imported: key != %{}}}
    end
  end

  def put(_attrs, _actor, _opts), do: {:error, %{field: "app", reason: "the App is an object"}}

  @fields ~w(app_id api_url installations private_key)

  @doc "The keys `put/3` reads, as `admin.github.put` declares them."
  @spec keys() :: [String.t()]
  def keys, do: @fields

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
  Read `session.create`'s `repository` for a session on `profile`: `"owner/name"` or
  `{owner, name, ref}`. Answers what the row keeps, `nil` for none, or why it will not do,
  as a sentence: no App here, no installation for that owner, or a profile that does not
  declare the Git host.
  """
  @spec repository(term(), String.t() | nil) :: {:ok, map() | nil} | {:error, String.t()}
  def repository(nil, _profile), do: {:ok, nil}

  def repository(text, profile) when is_binary(text) do
    case String.split(text, "/") do
      [owner, name] -> repository(%{"owner" => owner, "name" => name}, profile)
      _ -> {:error, "a repository is owner/name, or {owner, name, ref}"}
    end
  end

  def repository(%{} = given, profile) do
    given = Map.new(given, fn {key, value} -> {to_string(key), value} end)

    with :ok <- only_repository_keys(given),
         {:ok, owner} <- owner(given["owner"]),
         {:ok, name} <- name(given["name"]),
         {:ok, ref} <- ref(given["ref"]),
         {:ok, app} <- configured(),
         {:ok, _installation} <- installation_for(app, owner),
         :ok <- reachable(profile, app) do
      {:ok, %{"owner" => owner, "name" => name, "ref" => ref}}
    else
      {:error, reason} -> {:error, explain(reason)}
    end
  end

  def repository(_other, _profile),
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

  # A pod reaches the hosts its profile declares and no others, so a repository on a host
  # the profile does not name is refused here rather than left to time out on the pod.
  defp reachable(profile, app) do
    host = app |> api_url() |> git_url() |> URI.parse() |> Map.get(:host)

    declared =
      case profile && Fleet.get_profile(profile) do
        %{spec: spec} when is_map(spec) -> get_in(spec, ["egress", "gitHosts"]) || []
        _ -> []
      end

    if Enum.any?(declared, &Policy.matches?(host, &1)),
      do: :ok,
      else: {:error, {:host_not_declared, profile, host}}
  end

  # -- a session's token ------------------------------------------------------

  @doc """
  A new installation token for a session's repository, and where to clone it from:
  `{token, expires_at, url, host, username, ref, repository, installation_id}`.

  Asked of GitHub every time, narrowed to the one repository and `permissions/0`. The
  checks `repository/2` made at creation are made again, since the App, its installations
  and the profile may all have changed since.
  """
  @spec credential(Session.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def credential(session, opts \\ [])

  def credential(
        %Session{repository: %{"owner" => owner, "name" => name} = repository} = session,
        opts
      ) do
    with {:ok, app} <- configured(),
         {:ok, installation} <- installation_for(app, owner),
         :ok <- reachable(session.profile, app),
         {:ok, jwt} <- jwt(app, opts),
         {:ok, token, expires_at} <- exchange(app, installation, name, jwt) do
      git = git_url(api_url(app))

      {:ok,
       %{
         "token" => token,
         "expires_at" => expires_at,
         "url" => "#{git}/#{owner}/#{name}.git",
         "host" => URI.parse(git).host,
         "username" => "x-access-token",
         "ref" => repository["ref"],
         "repository" => "#{owner}/#{name}",
         "installation_id" => installation["installation_id"],
         "permissions" => @permissions
       }}
    end
  end

  def credential(%Session{}, _opts), do: {:error, :no_repository}

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
  defp exchange(app, installation, name, jwt) do
    url = "#{api_url(app)}/app/installations/#{installation["installation_id"]}/access_tokens"

    case Req.request(
           method: :post,
           url: url,
           json: %{"repositories" => [name], "permissions" => @permissions},
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

  def explain({:host_not_declared, profile, host}),
    do:
      "the worker profile #{profile || "(none)"} does not declare #{host} in egress.gitHosts, " <>
        "so its pods cannot reach it"

  def explain(:no_repository), do: "the session names no repository"
  def explain(:no_key), do: "the App's private key is not in OpenBao"

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
        "installation does not include that repository, or the App lacks Contents: read"

  def explain({:github, status, message, _owner, _name}),
    do: "GitHub answered #{status}#{if message, do: " (#{message})"}"

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
