defmodule Troupe.Plane.Artifacts do
  @moduledoc """
  Artifacts (#62): a page, a Markdown document or a file that an agent or a person
  published, kept on the plane as versions at one address.

  **What one is.** A row (`Artifact`) with its owner, the team its bytes count against,
  who may see it, where it came from (the session, the agent and whether that was a pod, a
  laptop or a person by hand) and the version its address serves; one row per version
  (`Version`), never updated, listing its files with their SHA-256 and content type; and the
  bytes in the object store under `artifacts/<id>/<n>/<path>`. Republishing makes version
  `n + 1` at the same address and keeps the others.

  **Who sees it.** Its owner; everybody, for `organisation`; the people a profile's grants
  cover, for `profile:<name>`. A platform administrator sees every one, since taking one
  down is theirs. Anybody else is told there is no such artifact, as for one that does not
  exist. Visibility is read again at every request, the artifacts host's included, so a
  person who leaves a profile's team stops seeing its artifacts at their next request.

  **Who publishes it.** Anybody signed in, for a profile they are covered by; for the
  organisation, anybody or only platform administrators as `artifacts_publish_organisation`
  says. Only the owner republishes or deletes one, and a platform administrator deletes any
  (a takedown). Every publish, republish and delete is in the audit trail with who did it and
  the session it came from; never the content.

  **What it may hold.** A file is at most 16 MiB and a version 64 MiB, and a team's artifacts
  together at most its `artifact_quota_bytes`, every version counted (zero is no quota). What
  one call can carry is less than that: the door's own limit on a body.

  **Where it is read.** Never on the plane's host. The artifacts host
  (`Troupe.Plane.Web.Artifacts`) serves it, on an origin of its own, to a viewer who came
  through a ticket this module signs (`ticket/3`) and holds the cookie that host set.
  """

  import Ecto.Query

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, Identity, Repo, Settings}
  alias Troupe.Plane.Artifacts.{Artifact, Version}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.Error

  @kinds ~w(html markdown file)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024
  @max_files 500
  @max_title 200
  @max_path 512

  # A ticket is a link the console opens at once: a minute is long enough to load a tab and
  # short enough that one copied out of a history is dead by the time anybody reads it.
  @ticket_seconds 60
  # The artifacts host's own sign-in, which a viewer renews by opening another from the
  # plane: an hour, and every request still checks who they are now.
  @viewer_seconds 3600

  @doc "The kinds an artifact may be."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc "A file's limit and a version's, in bytes."
  @spec limits() :: %{file: pos_integer(), version: pos_integer()}
  def limits, do: %{file: @max_file_bytes, version: @max_version_bytes}

  @doc "How long the artifacts host's cookie lasts, in seconds."
  @spec viewer_seconds() :: pos_integer()
  def viewer_seconds, do: @viewer_seconds

  @doc "Whether an administrator has left artifacts on."
  @spec enabled?() :: boolean()
  def enabled?, do: Settings.get("artifacts_enabled") != false

  @doc """
  The artifacts host's own address, as a viewer's browser reaches it, or `nil` where this
  plane was deployed without one.
  """
  @spec host_url() :: String.t() | nil
  def host_url do
    case Keyword.get(config(), :url) do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _none -> nil
    end
  end

  @doc "Where an artifact's current version is, on the artifacts host."
  @spec url(String.t()) :: String.t() | nil
  def url(id), do: host_url() && "#{host_url()}/a/#{id}/"

  # -- publishing -----------------------------------------------------------------

  @doc """
  Publish `params` (`title`, `kind`, `visibility`, `files`, and `id` to republish) as `user`.

  `opts`: `:session`, the pod's session it came from, whose team its bytes count against
  and whose profile it records; `:agent`, the agent that called the tool; `:origin`, what a
  client said of where it came from; `:platform_admin?`.
  """
  @spec publish(User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def publish(%User{} = user, params, opts \\ []) when is_map(params) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, title} <- title(params["title"]),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, visibility} <- visibility(params["visibility"]),
         :ok <- may_publish(user, visibility, admin?),
         {:ok, files} <- files(params["files"]),
         {:ok, _entry} <- entry(kind, files),
         {:ok, team_id} <- team_for(user, visibility, opts[:session]),
         {:ok, existing} <- existing(params["id"], user, admin?) do
      write(user, existing, %{
        title: title,
        kind: kind,
        visibility: visibility,
        files: files,
        team_id: team_id,
        origin: origin(opts),
        profile: opts[:session] && opts[:session].profile
      })
    end
  end

  defp on do
    if enabled?(),
      do: :ok,
      else: {:error, Error.new(:forbidden, %{reason: "artifacts are switched off on this plane"})}
  end

  defp title(title) when is_binary(title) do
    title = title |> String.split() |> Enum.join(" ")

    cond do
      title == "" ->
        {:error, invalid("an artifact needs a title")}

      String.length(title) > @max_title ->
        {:error, invalid("a title is at most #{@max_title} characters")}

      true ->
        {:ok, title}
    end
  end

  defp title(_title), do: {:error, invalid("an artifact needs a title")}

  defp kind(kind) when kind in @kinds, do: {:ok, kind}
  defp kind(other), do: {:error, invalid("kind is html, markdown or file, not #{inspect(other)}")}

  @doc "A visibility as stored, or why it is not one."
  @spec visibility(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def visibility("organisation"), do: {:ok, "organisation"}

  def visibility("profile:" <> name = visibility) when name != "" do
    if name =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
      do: {:ok, visibility},
      else: {:error, invalid("#{inspect(name)} is not a profile's name")}
  end

  def visibility(other),
    do: {:error, invalid("visibility is organisation or profile:<name>, not #{inspect(other)}")}

  defp may_publish(user, "organisation", admin?) do
    if Settings.get("artifacts_publish_organisation") == :platform_admins and not admin?,
      do:
        {:error,
         Error.new(:forbidden, %{
           reason:
             "only platform administrators publish to the whole organisation here; publish to a profile's people (profile:<name>) instead"
         })},
      else: covered(user)
  end

  defp may_publish(user, "profile:" <> name, _admin?) do
    if name in profiles_of(user),
      do: :ok,
      else:
        {:error,
         Error.new(:forbidden, %{
           reason: "you are not among profile #{name}'s people, so you cannot publish to them"
         })}
  end

  # A person, or a principal of a team: somebody the organisation's artifacts are for.
  defp covered(%User{kind: "service"}), do: :ok
  defp covered(%User{id: id}) when is_binary(id), do: :ok

  defp covered(_user),
    do: {:error, Error.new(:forbidden, %{reason: "not a person of this plane"})}

  # Every file: a relative path under the artifact, decoded, each within the limit and all of
  # them within a version's.
  defp files(files) when is_list(files) and files != [] and length(files) <= @max_files do
    files
    |> Enum.reduce_while({:ok, [], 0, MapSet.new()}, fn file, {:ok, acc, total, seen} ->
      with {:ok, path} <- path(file),
           :ok <- unseen(path, seen),
           {:ok, body} <- body(file, path),
           {:ok, type} <- content_type(file, path),
           total = total + byte_size(body),
           :ok <- within_version(total) do
        entry = %{
          path: path,
          body: body,
          content_type: type,
          sha256: sha256(body),
          bytes: byte_size(body)
        }

        {:cont, {:ok, [entry | acc], total, MapSet.put(seen, path)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _total, _seen} -> {:ok, Enum.sort_by(files, & &1.path)}
      error -> error
    end
  end

  defp files(files) when is_list(files) and length(files) > @max_files,
    do: {:error, invalid("an artifact has at most #{@max_files} files")}

  defp files(_files),
    do: {:error, invalid("an artifact needs files: [{path, content_type, bytes}]")}

  @doc """
  A path as an artifact keeps it, or why it is refused: relative, `/`-separated, no empty,
  `.` or `..` segment, and not starting with a segment the host's addresses take (`v<n>`).
  """
  @spec normalise_path(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalise_path(path) when is_binary(path) do
    case Enum.find(path_rules(), fn {refused?, _why} -> refused?.(path) end) do
      nil -> {:ok, path}
      {_refused?, why} -> {:error, why.(path)}
    end
  end

  def normalise_path(other), do: {:error, "a path is a string, not #{inspect(other)}"}

  # Each a test that refuses a path and the sentence that says why, in the order they hold.
  defp path_rules do
    [
      {&(&1 == "" or byte_size(&1) > @max_path), fn _ -> "a path is 1 to #{@max_path} bytes" end},
      {&(String.starts_with?(&1, "/") or String.contains?(&1, "\\")),
       &"#{&1} is not a relative path with / between its parts"},
      {&(not String.valid?(&1) or &1 =~ ~r/[\x00-\x1f\x7f]/),
       &"#{inspect(&1)} has characters a path may not"},
      {&Enum.any?(String.split(&1, "/"), fn part -> part in ["", ".", ".."] end),
       &"#{&1} has an empty, . or .. part"},
      {&(hd(String.split(&1, "/")) =~ ~r/\Av\d+\z/),
       &"#{&1} starts with #{hd(String.split(&1, "/"))}, which the artifact's addresses use for its versions"}
    ]
  end

  defp path(%{"path" => path}) do
    case normalise_path(path) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, invalid(reason)}
    end
  end

  defp path(_file), do: {:error, invalid("each file needs a path")}

  defp unseen(path, seen) do
    if MapSet.member?(seen, path), do: {:error, invalid("#{path} is there twice")}, else: :ok
  end

  defp body(%{"bytes" => encoded}, path) when is_binary(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, body} when byte_size(body) > @max_file_bytes ->
        {:error,
         Error.new(:payload_too_large, %{
           path: path,
           limit: @max_file_bytes,
           reason:
             "#{path} is #{byte_size(body)} bytes, past the #{@max_file_bytes} a file may be"
         })}

      {:ok, body} ->
        {:ok, body}

      :error ->
        {:error, invalid("#{path}'s bytes are not base64")}
    end
  end

  defp body(_file, path), do: {:error, invalid("#{path} has no bytes (base64)")}

  defp within_version(total) when total > @max_version_bytes,
    do:
      {:error,
       Error.new(:payload_too_large, %{
         limit: @max_version_bytes,
         reason: "a version is at most #{@max_version_bytes} bytes"
       })}

  defp within_version(_total), do: :ok

  defp content_type(%{"content_type" => type}, _path) when is_binary(type) and type != "" do
    if type =~
         ~r{\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*(\s*;\s*charset=[A-Za-z0-9_-]+)?\z},
       do: {:ok, String.downcase(type)},
       else: {:error, invalid("#{inspect(type)} is not a content type")}
  end

  defp content_type(_file, path), do: {:ok, MIME.from_path(path)}

  @doc """
  The file an artifact's address opens: `index.html` or its one top-level HTML file for a
  page, `index.md`, `README.md` or its one Markdown file for a document, the one file for a
  file.
  """
  @spec entry(String.t(), [map()]) :: {:ok, String.t()} | {:error, Error.t()}
  def entry(kind, files) do
    paths = Enum.map(files, &(Map.get(&1, :path) || Map.get(&1, "path")))
    top = Enum.reject(paths, &String.contains?(&1, "/"))

    case kind do
      "html" ->
        pick(
          paths,
          top,
          "index.html",
          ~w(.html .htm),
          "a page needs index.html, or one .html file at its top"
        )

      "markdown" ->
        pick_markdown(paths, top)

      "file" ->
        if length(paths) == 1,
          do: {:ok, hd(paths)},
          else: {:error, invalid("a file artifact is one file")}
    end
  end

  defp pick(paths, top, named, extensions, reason) do
    cond do
      named in paths -> {:ok, named}
      match?([_], only(top, extensions)) -> {:ok, hd(only(top, extensions))}
      true -> {:error, invalid(reason)}
    end
  end

  defp pick_markdown(paths, top) do
    cond do
      "index.md" in paths ->
        {:ok, "index.md"}

      "README.md" in paths ->
        {:ok, "README.md"}

      match?([_], only(top, ~w(.md .markdown))) ->
        {:ok, hd(only(top, ~w(.md .markdown)))}

      true ->
        {:error, invalid("a document needs index.md, README.md, or one .md file at its top")}
    end
  end

  defp only(paths, extensions),
    do: Enum.filter(paths, &(String.downcase(Path.extname(&1)) in extensions))

  # Which team's quota the bytes count against: the pod session's team; else the team that
  # grants the profile it is for; else the publisher's first team. Nobody in no team publishes.
  defp team_for(_user, _visibility, %Session{team_id: team_id}) when is_binary(team_id),
    do: {:ok, team_id}

  defp team_for(user, visibility, _session) do
    granting =
      case visibility do
        "profile:" <> name ->
          user |> Identity.profiles_for() |> Enum.find_value(&(&1.profile == name && &1.team.id))

        _organisation ->
          nil
      end

    case granting || first_team(user) do
      nil ->
        {:error,
         Error.new(:forbidden, %{
           reason:
             "publishing needs a team, whose quota the artifact counts against, and you are in none"
         })}

      team_id ->
        {:ok, team_id}
    end
  end

  defp first_team(user) do
    case Identity.teams_for(user) do
      [team | _] -> team.id
      [] -> nil
    end
  end

  defp existing(nil, _user, _admin?), do: {:ok, nil}

  defp existing(id, user, admin?) when is_binary(id) do
    case visible(id, user, admin?) do
      {:ok, %Artifact{owner_id: owner} = artifact} when owner == user.id and is_binary(owner) ->
        {:ok, artifact}

      {:ok, _theirs} ->
        {:error,
         Error.new(:forbidden, %{id: id, reason: "only its owner republishes an artifact"})}

      {:error, _} = error ->
        error
    end
  end

  defp existing(other, _user, _admin?),
    do: {:error, invalid("id is an artifact's id, not #{inspect(other)}")}

  defp origin(opts) do
    case opts[:session] do
      %Session{} = session ->
        %{"session_id" => session.id, "agent" => opts[:agent], "where" => "pod"}

      nil ->
        said = if is_map(opts[:origin]), do: opts[:origin], else: %{}
        session_id = string_or_nil(said["session_id"])

        %{
          "session_id" => session_id,
          "agent" => string_or_nil(said["agent"]),
          "where" => if(session_id, do: "laptop", else: "person")
        }
    end
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp string_or_nil(value) when is_binary(value) and byte_size(value) in 1..200, do: value
  defp string_or_nil(_value), do: nil

  defp write(user, existing, attrs) do
    bytes = attrs.files |> Enum.map(& &1.bytes) |> Enum.sum()
    hash = version_hash(attrs.files)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      artifact = lock(existing) || new_artifact(user, attrs, now)
      n = (existing && artifact.version + 1) || 1

      with :ok <- republishable(existing, attrs),
           :ok <- within_quota(attrs.team_id, bytes, existing),
           :ok <- put_objects(artifact.id, n, attrs.files) do
        Repo.insert!(%Version{
          artifact_id: artifact.id,
          n: n,
          hash: hash,
          bytes: bytes,
          files: Enum.map(attrs.files, &file_json/1),
          published_by: user.subject,
          published_at: now
        })

        artifact =
          artifact
          |> Ecto.Changeset.change(%{
            title: attrs.title,
            visibility: attrs.visibility,
            version: n,
            bytes: bytes,
            total_bytes: artifact.total_bytes + bytes,
            updated_at: now
          })
          |> Repo.update!()

        {:ok, _event} =
          Audit.record(
            user.subject,
            "artifact.publish",
            artifact.id,
            audit_detail(artifact, existing, n, hash, bytes)
          )

        artifact
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, artifact} ->
        {:ok,
         artifact |> Repo.preload([:owner, :team, :versions], force: true) |> to_json(user, true)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp lock(nil), do: nil

  defp lock(%Artifact{id: id}),
    do: Repo.one!(from(a in Artifact, where: a.id == ^id, lock: "FOR UPDATE"))

  defp new_artifact(user, attrs, now) do
    Repo.insert!(%Artifact{
      id: new_id(),
      owner_id: user.id,
      team_id: attrs.team_id,
      title: attrs.title,
      kind: attrs.kind,
      visibility: attrs.visibility,
      profile: attrs.profile,
      origin: attrs.origin,
      version: 0,
      bytes: 0,
      total_bytes: 0,
      inserted_at: now,
      updated_at: now
    })
  end

  defp republishable(nil, _attrs), do: :ok
  defp republishable(%Artifact{kind: kind}, %{kind: kind}), do: :ok

  defp republishable(%Artifact{kind: kind}, _attrs),
    do:
      {:error,
       invalid("this artifact is #{kind}; an artifact keeps its kind, so publish another one")}

  defp within_quota(team_id, bytes, _existing) do
    quota =
      case Repo.get(Identity.Team, team_id) do
        %{artifact_quota_bytes: quota} -> quota || 0
        nil -> 0
      end

    used = usage_of(team_id)

    if quota > 0 and used + bytes > quota,
      do:
        {:error,
         Error.new(:payload_too_large, %{
           quota: quota,
           used: used,
           reason:
             "the team's artifacts would hold #{used + bytes} bytes, past its quota of #{quota}; " <>
               "delete one, or ask its administrator for more"
         })},
      else: :ok
  end

  defp put_objects(id, n, files) do
    store = store()

    Enum.reduce_while(files, :ok, fn file, :ok ->
      case ObjectStore.put(store, key(id, n, file.path), file.body,
             content_type: file.content_type
           ) do
        {:ok, _put} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:unavailable, %{
              reason: "the object store refused #{file.path}: #{inspect(reason)}"
            })}}
      end
    end)
  end

  defp audit_detail(artifact, existing, n, hash, bytes) do
    %{
      "version" => n,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      "bytes" => bytes,
      "hash" => hash,
      "session" => artifact.origin["session_id"],
      "agent" => artifact.origin["agent"]
    }
    |> then(fn detail ->
      if existing && existing.visibility != artifact.visibility,
        do: Map.put(detail, "visibility_from", existing.visibility),
        else: detail
    end)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp file_json(file),
    do: %{
      "path" => file.path,
      "sha256" => file.sha256,
      "content_type" => file.content_type,
      "bytes" => file.bytes
    }

  defp version_hash(files) do
    lines = Enum.map_join(files, "", &"#{&1.path}\0#{&1.sha256}\n")
    "sha256:" <> sha256(lines)
  end

  defp sha256(body), do: :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower)

  defp new_id do
    "art-" <> (10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))
  end

  defp key(id, n, path), do: "artifacts/#{id}/#{n}/#{path}"

  # -- reading --------------------------------------------------------------------

  @doc "What `user` may see, newest published first, narrowed by `mine` or `visibility`."
  @spec list(User.t(), map(), keyword()) :: {:ok, map()}
  def list(%User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)
    profiles = profiles_of(user)

    artifacts =
      if enabled?() do
        user
        |> visible_query(profiles, admin?)
        |> narrow(params, user)
        |> order_by([a], desc: a.updated_at)
        |> limit(500)
        |> preload([:owner, :team])
        |> Repo.all()
        |> Enum.map(&to_json(&1, user, admin?))
      else
        []
      end

    {:ok,
     %{
       "enabled" => enabled?(),
       "profiles" => profiles,
       "publish_organisation" =>
         to_string(Settings.get("artifacts_publish_organisation") || :everyone),
       "artifacts" => artifacts
     }}
  end

  defp visible_query(_user, _profiles, true), do: from(a in Artifact)

  defp visible_query(user, profiles, false) do
    visibilities = ["organisation" | Enum.map(profiles, &"profile:#{&1}")]
    owner = user.id

    if is_binary(owner),
      do: from(a in Artifact, where: a.owner_id == ^owner or a.visibility in ^visibilities),
      else: from(a in Artifact, where: a.visibility in ^visibilities)
  end

  defp narrow(query, %{"mine" => true}, %User{id: id}) when is_binary(id),
    do: where(query, [a], a.owner_id == ^id)

  defp narrow(query, %{"mine" => true}, _user), do: where(query, [a], false)

  defp narrow(query, %{"visibility" => visibility}, _user) when is_binary(visibility),
    do: where(query, [a], a.visibility == ^visibility)

  defp narrow(query, _params, _user), do: query

  @doc "One artifact with its versions, if `user` may see it."
  @spec get(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- visible(id, user, admin?) do
      {:ok, artifact |> Repo.preload([:owner, :team, :versions]) |> to_json(user, admin?)}
    end
  end

  @doc """
  The artifact `id` if `user` may see it, read now. `not_found` for one they may not, as for
  one that is not there, and for every one while artifacts are off.
  """
  @spec visible(term(), User.t(), boolean()) :: {:ok, Artifact.t()} | {:error, Error.t()}
  def visible(id, %User{} = user, admin?) when is_binary(id) do
    with true <- enabled?(),
         %Artifact{} = artifact <- Repo.get(Artifact, id),
         true <- admin? or sees?(artifact, user) do
      {:ok, artifact}
    else
      _no -> {:error, Error.new(:not_found, %{id: id})}
    end
  end

  def visible(id, _user, _admin?), do: {:error, Error.new(:not_found, %{id: id})}

  defp sees?(%Artifact{owner_id: owner}, %User{id: owner}) when is_binary(owner), do: true
  defp sees?(%Artifact{visibility: "organisation"}, user), do: covered(user) == :ok
  defp sees?(%Artifact{visibility: "profile:" <> name}, user), do: name in profiles_of(user)
  defp sees?(_artifact, _user), do: false

  defp profiles_of(user),
    do: user |> Identity.profiles_for() |> Enum.map(& &1.profile) |> Enum.uniq() |> Enum.sort()

  @doc """
  One file of one version for the artifacts host: `version` is a number or `:current`, and
  `path` the file's, or `nil` for the version's entry. Visibility as `visible/3` reads it.
  """
  @spec fetch(String.t(), pos_integer() | :current, String.t() | nil, User.t()) ::
          {:ok, %{artifact: Artifact.t(), version: Version.t(), file: map(), body: binary()}}
          | {:error, :not_found}
  def fetch(id, version, path, %User{} = user) do
    with {:ok, artifact} <- visible(id, user, platform_admin?(user)),
         %Version{} = found <- version_of(artifact, version),
         {:ok, path} <- file_path(artifact, found, path),
         %{} = file <- Enum.find(found.files, &(&1["path"] == path)),
         {:ok, body} <- ObjectStore.get(store(), key(artifact.id, found.n, path)) do
      {:ok, %{artifact: artifact, version: found, file: file, body: body}}
    else
      _no -> {:error, :not_found}
    end
  end

  defp version_of(%Artifact{id: id, version: n}, :current),
    do: Repo.get_by(Version, artifact_id: id, n: n)

  defp version_of(%Artifact{id: id}, n) when is_integer(n),
    do: Repo.get_by(Version, artifact_id: id, n: n)

  defp file_path(artifact, version, nil) do
    case entry(artifact.kind, version.files) do
      {:ok, path} -> {:ok, path}
      _none -> :error
    end
  end

  defp file_path(_artifact, _version, path), do: {:ok, path}

  defp platform_admin?(user), do: Admin.actor_for(user).role == :platform_admin

  # -- deleting -------------------------------------------------------------------

  @doc """
  Delete an artifact, every version and every byte: its owner's, or a platform
  administrator's takedown. Audited as `artifact.delete` with which it was.
  """
  @spec delete(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- visible(id, user, admin?),
         {:ok, how} <- deleter(artifact, user, admin?),
         :ok <- delete_objects(artifact.id) do
      Repo.delete!(artifact)

      {:ok, _event} =
        Audit.record(
          user.subject,
          "artifact.delete",
          artifact.id,
          %{
            "title" => artifact.title,
            "visibility" => artifact.visibility,
            "versions" => artifact.version,
            "by" => how,
            "session" => artifact.origin["session_id"]
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
        )

      {:ok, %{"deleted" => true, "id" => artifact.id}}
    end
  end

  defp deleter(%Artifact{owner_id: owner}, %User{id: owner}, _admin?) when is_binary(owner),
    do: {:ok, "owner"}

  defp deleter(_artifact, _user, true), do: {:ok, "takedown"}

  defp deleter(artifact, _user, false),
    do:
      {:error,
       Error.new(:forbidden, %{
         id: artifact.id,
         reason: "only its owner or a platform administrator deletes an artifact"
       })}

  defp delete_objects(id) do
    case store() do
      %ObjectStore{} = store ->
        case ObjectStore.delete_prefix(store, "artifacts/#{id}/") do
          {:ok, _deleted} ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:unavailable, %{
               reason: "the object store refused the delete: #{inspect(reason)}"
             })}
        end

      _other ->
        :ok
    end
  end

  # -- what a team holds ----------------------------------------------------------

  @doc "What a team's artifacts hold in the object store, every version counted, in bytes."
  @spec usage(Identity.Team.t() | String.t()) :: non_neg_integer()
  def usage(%Identity.Team{id: id}), do: usage_of(id)
  def usage(id) when is_binary(id), do: usage_of(id)

  defp usage_of(team_id) do
    Repo.one(
      from(a in Artifact,
        where: a.team_id == ^team_id,
        select: type(coalesce(sum(a.total_bytes), 0), :integer)
      )
    ) || 0
  end

  # -- the artifacts host's sign-in -------------------------------------------------

  @doc """
  A one-time address on the artifacts host that signs `user` in there and opens the
  artifact: the only way onto that host, so a viewer comes through the plane, as who the
  plane says they are. `nil` version is the current one.
  """
  @spec ticket(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def ticket(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)
    version = Keyword.get(opts, :version)

    with {:ok, artifact} <- visible(id, user, admin?),
         :ok <- version_there(artifact, version),
         host when is_binary(host) <-
           host_url() ||
             {:error,
              Error.new(:unavailable, %{
                reason: "this plane was deployed without an artifacts host (plane.artifactsHost)"
              })} do
      claims = %{"s" => user.subject, "a" => artifact.id, "v" => version, "n" => nonce()}
      token = Plug.Crypto.sign(secret(), "troupe artifact ticket", claims)

      {:ok, %{"url" => "#{host}/enter?ticket=#{token}", "expires_in" => @ticket_seconds}}
    end
  end

  defp version_there(_artifact, nil), do: :ok

  defp version_there(artifact, n) when is_integer(n) and n >= 1 and n <= artifact.version do
    if Repo.get_by(Version, artifact_id: artifact.id, n: n),
      do: :ok,
      else: {:error, Error.new(:not_found, %{version: n})}
  end

  defp version_there(_artifact, n), do: {:error, Error.new(:not_found, %{version: n})}

  @doc """
  A ticket from `ticket/3`, redeemed once: who it signs in and what it opens, or `:error`
  for one that is forged, older than a minute, or redeemed already.
  """
  @spec redeem(String.t()) ::
          {:ok, %{subject: String.t(), id: String.t(), version: pos_integer() | nil}} | :error
  def redeem(token) when is_binary(token) do
    with {:ok, %{"s" => subject, "a" => id, "n" => nonce} = claims} <-
           Plug.Crypto.verify(secret(), "troupe artifact ticket", token, max_age: @ticket_seconds),
         :ok <- spend(nonce) do
      {:ok, %{subject: subject, id: id, version: claims["v"]}}
    else
      _no -> :error
    end
  end

  def redeem(_token), do: :error

  defp spend(nonce) do
    now = NaiveDateTime.utc_now()

    Repo.delete_all(
      from(t in "artifact_tickets", where: t.used_at < ^NaiveDateTime.add(now, -3600))
    )

    case Repo.insert_all("artifact_tickets", [%{nonce: nonce, used_at: now}],
           on_conflict: :nothing
         ) do
      {1, _} -> :ok
      {0, _} -> :error
    end
  end

  @doc "The artifacts host's cookie for `subject`, signed, for `viewer_seconds/0`."
  @spec viewer_cookie(String.t()) :: String.t()
  def viewer_cookie(subject),
    do: Plug.Crypto.sign(secret(), "troupe artifact viewer", %{"s" => subject})

  @doc "Who the artifacts host's cookie says the viewer is, if still somebody active here."
  @spec viewer(String.t() | nil) :: {:ok, User.t()} | :error
  def viewer(cookie) when is_binary(cookie) do
    with {:ok, %{"s" => subject}} <-
           Plug.Crypto.verify(secret(), "troupe artifact viewer", cookie,
             max_age: @viewer_seconds
           ),
         %User{} = user <- Identity.get_user(subject),
         true <- user.active != false do
      {:ok, user}
    else
      _no -> :error
    end
  end

  def viewer(_cookie), do: :error

  defp nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # The plane's own secret, with salts of these two alone, so neither a ticket nor the
  # artifacts host's cookie is anything the plane's own cookies would take, or the other way.
  defp secret do
    :troupe_plane
    |> Application.get_env(Troupe.Plane.Web.Endpoint, [])
    |> Keyword.fetch!(:secret_key_base)
  end

  # -- the answer -----------------------------------------------------------------

  @doc false
  @spec to_json(Artifact.t(), User.t(), boolean()) :: map()
  def to_json(%Artifact{} = artifact, %User{} = user, admin?) do
    mine = is_binary(artifact.owner_id) and artifact.owner_id == user.id

    %{
      "id" => artifact.id,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      "owner" => person(artifact.owner),
      "mine" => mine,
      "origin" => Map.merge(%{"profile" => artifact.profile}, artifact.origin || %{}),
      "team" => team_name(artifact.team),
      "version" => artifact.version,
      "bytes" => artifact.bytes,
      "url" => url(artifact.id),
      "created_at" => artifact.inserted_at,
      "published_at" => artifact.updated_at,
      "may_delete" => mine or admin?
    }
    |> put_versions(artifact)
  end

  defp put_versions(json, %Artifact{versions: versions} = artifact) when is_list(versions) do
    people = versions |> Enum.map(& &1.published_by) |> Enum.uniq() |> people()

    Map.put(
      json,
      "versions",
      versions
      |> Enum.sort_by(& &1.n, :desc)
      |> Enum.map(fn version ->
        %{
          "n" => version.n,
          "hash" => version.hash,
          "bytes" => version.bytes,
          "files" => version.files,
          "published_by" =>
            Map.get(people, version.published_by, %{
              "subject" => version.published_by,
              "display_name" => nil
            }),
          "published_at" => version.published_at,
          "url" => host_url() && "#{host_url()}/a/#{artifact.id}/v#{version.n}/"
        }
      end)
    )
  end

  defp put_versions(json, _artifact), do: json

  defp people(subjects) do
    from(u in User, where: u.subject in ^subjects)
    |> Repo.all()
    |> Map.new(&{&1.subject, person(&1)})
  end

  defp person(%User{} = user),
    do: %{"subject" => user.subject, "display_name" => user.display_name}

  defp person(_none), do: nil

  defp team_name(%Identity.Team{name: name}), do: name
  defp team_name(_none), do: nil

  # -- plumbing -------------------------------------------------------------------

  defp invalid(reason), do: Error.new(:invalid_params, %{reason: reason})

  defp config, do: Application.get_env(:troupe_plane, :artifacts, [])

  # The store artifacts are kept in: the plane's, or the one a test put in its place.
  defp store, do: Keyword.get(config(), :store) || ObjectStore.from_env()
end
