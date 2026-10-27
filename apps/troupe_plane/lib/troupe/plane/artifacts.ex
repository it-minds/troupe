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

  **Who sees it.** Its owner, and whoever a link of theirs gave it to; nobody else, for
  `private`, the default; everybody, for `organisation`; a team's members, for
  `team:<name>`; the people a profile's grants cover, for `profile:<name>`. A platform
  administrator sees every one but another person's private ones, and a team's
  administrator their team's, since taking one down is theirs. Anybody else is told there is
  no such artifact, as for one that does not exist. Visibility is read again at every
  request, the artifacts host's included, so a person who leaves a team stops seeing its
  artifacts at their next request.

  **Who publishes it.** Anybody signed in, privately, to a team they are in or a profile they
  are covered by (a platform administrator to any team); for the organisation, anybody or
  only platform administrators as `artifacts_publish_organisation` says. Only the owner
  republishes or deletes one; a platform administrator takes any down, a private one too,
  and a team's administrator their team's. A team's artifact counts against that team's
  quota. Every publish, republish and delete is in the audit trail with who did it and the
  session it came from; never the content.

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
  alias Troupe.Plane.Artifacts.{Artifact, Previews, Shares, Uploads, Version}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.Session
  alias Troupe.Protocol.Error

  @kinds ~w(html markdown file)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024
  @max_files 500
  @max_title 200
  @max_path 512
  @max_segment 255
  @max_note 500

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
  def publish(user, params, opts \\ [])

  # With an id, a new version of one already there: a put, by its owner or an edit link's
  # holder, which may also say what it is called and, the owner's alone, who may open it.
  def publish(%User{} = user, %{"id" => id} = params, opts) when not is_nil(id) do
    with :ok <- on(),
         {:ok, _title} <- title(params["title"]),
         {:ok, _kind} <- kind(params["kind"]),
         {:ok, _visibility} <- kept_visibility(params["visibility"]) do
      put(user, params, opts)
    end
  end

  def publish(%User{} = user, params, opts) when is_map(params) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, title} <- title(params["title"]),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, visibility} <- new_visibility(params["visibility"]),
         :ok <- may_publish(user, visibility, admin?),
         {:ok, note} <- note(params["note"]),
         {:ok, files} <- incoming(params, user),
         {:ok, _entry} <- entry(kind, files),
         {:ok, team_id} <- team_for(user, visibility, opts[:session]) do
      write(user, nil, %{
        title: title,
        kind: kind,
        visibility: visibility,
        files: files,
        team_id: team_id,
        origin: origin(opts),
        profile: opts[:session] && opts[:session].profile,
        note: note
      })
      |> uploaded(params)
    end
  end

  @doc """
  A new version of artifact `params["id"]` at the same address: `files` (or `upload`, a
  handle from `begin_upload/2`), `note`, and `title`; with `base`, the version the files
  were edited on, whose files not sent are carried as they are, and which must still be the
  newest. Its owner's, or an `edit` link's holder's; `visibility` moves it, the owner's alone.
  """
  @spec put(User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def put(%User{} = user, params, opts \\ []) when is_map(params) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact, role} <- editable(params["id"], user, admin?),
         {:ok, title} <- title(params["title"] || artifact.title),
         :ok <- same_kind(artifact, params["kind"]),
         {:ok, visibility} <- visibility(params["visibility"] || artifact.visibility),
         :ok <- may_move(artifact, visibility, role, user, admin?),
         {:ok, note} <- note(params["note"]),
         {:ok, base} <- base(artifact, params["base"]),
         {:ok, sent} <- incoming_over(base, params, user),
         files = carry(base, sent),
         {:ok, _entry} <- entry(artifact.kind, files),
         {:ok, team_id} <- team_of(artifact, user, visibility, opts[:session]) do
      write(user, artifact, %{
        title: title,
        kind: artifact.kind,
        visibility: visibility,
        files: files,
        team_id: team_id,
        note: note,
        role: role
      })
      |> uploaded(params)
    end
  end

  # An upload handle is spent once its files are a version, and kept for another try if not.
  defp uploaded({:ok, _artifact} = done, %{"upload" => handle}) when is_binary(handle) do
    Uploads.finish(handle, store())
    done
  end

  defp uploaded(result, _params), do: result

  @doc """
  Republish version `n`'s files as the next version, with the note "rolled back to v<n>":
  nothing is overwritten, and the files are the old version's objects, not copies. Whoever
  may put. Audited as `artifact.rollback`.
  """
  @spec rollback(String.t(), pos_integer(), User.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def rollback(id, n, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact, role} <- editable(id, user, admin?),
         %Version{} = old <- (is_integer(n) && version_of(artifact, n)) || nil,
         {:ok, team_id} <- team_of(artifact, user, artifact.visibility, nil) do
      write(user, artifact, %{
        title: artifact.title,
        kind: artifact.kind,
        visibility: artifact.visibility,
        files: Enum.map(old.files, &carried(&1, old.n)),
        team_id: team_id,
        note: "rolled back to v#{old.n}",
        rolled_back_to: old.n,
        role: role
      })
    else
      nil -> {:error, Error.new(:not_found, %{id: id, version: n})}
      {:error, _} = error -> error
    end
  end

  @doc """
  Pin version `n` as the one the artifact's address serves, or `nil` for the newest again.
  The owner's alone; audited as `artifact.pin`.
  """
  @spec pin(String.t(), pos_integer() | nil, User.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def pin(id, n, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, admin?, "pins a version of"),
         :ok <- pinnable(artifact, n) do
      serves = version_of(artifact, n || artifact.version)

      artifact =
        artifact |> Ecto.Changeset.change(pinned: n, bytes: serves.bytes) |> Repo.update!()

      {:ok, _event} =
        Audit.record(user.subject, "artifact.pin", artifact.id, %{"pinned" => n, "newest" => artifact.version})

      {:ok, answer(artifact, user, admin?)}
    end
  end

  defp pinnable(_artifact, nil), do: :ok

  defp pinnable(artifact, n) when is_integer(n) do
    if version_of(artifact, n),
      do: :ok,
      else: {:error, Error.new(:not_found, %{id: artifact.id, version: n})}
  end

  defp pinnable(_artifact, other),
    do: {:error, invalid("version is a version's number, or null for the newest, not #{inspect(other)}")}

  @doc """
  The owner's switch for this artifact's public links: off, none of them opens, whatever the
  administrator's setting. Audited as `artifact.public`.
  """
  @spec public_links(String.t(), boolean(), User.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def public_links(id, enabled, %User{} = user, opts \\ []) when is_boolean(enabled) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, admin?, "switches the public links of") do
      artifact = artifact |> Ecto.Changeset.change(public_links: enabled) |> Repo.update!()
      {:ok, _event} = Audit.record(user.subject, "artifact.public", artifact.id, %{"enabled" => enabled})
      {:ok, answer(artifact, user, admin?)}
    end
  end

  defp answer(artifact, user, admin?),
    do: artifact |> Repo.preload([:owner, :team, :versions], force: true) |> to_json(user, admin?)

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
  def visibility("private"), do: {:ok, "private"}

  def visibility("profile:" <> name = visibility) when name != "" do
    if name =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
      do: {:ok, visibility},
      else: {:error, invalid("#{inspect(name)} is not a profile's name")}
  end

  def visibility("team:" <> name = visibility) when name != "" do
    if name =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
      do: {:ok, visibility},
      else: {:error, invalid("#{inspect(name)} is not a team's name")}
  end

  def visibility(other),
    do:
      {:error,
       invalid(
         "visibility is private, organisation, team:<name> or profile:<name>, not #{inspect(other)}"
       )}

  # Who a new artifact is for when its publisher says nothing: its owner alone.
  defp new_visibility(nil), do: visibility("private")
  defp new_visibility(visibility), do: visibility(visibility)

  # A republish that says nothing keeps who it is for.
  defp kept_visibility(nil), do: {:ok, nil}
  defp kept_visibility(visibility), do: visibility(visibility)

  defp may_publish(user, "organisation", admin?) do
    if Settings.get("artifacts_publish_organisation") == :platform_admins and not admin?,
      do:
        {:error,
         Error.new(:forbidden, %{
           reason:
             "only platform administrators publish to the whole organisation here; publish to a team (team:<name>) or a profile's people (profile:<name>) instead"
         })},
      else: covered(user)
  end

  # A team's: one its publisher is in. A platform administrator publishes to any team there
  # is; for anybody else, one that is not there is refused as one they are not in.
  defp may_publish(user, "team:" <> name, admin?) do
    teams = teams_of(user)

    cond do
      name in teams ->
        :ok

      admin? and Identity.get_team(name) != nil ->
        :ok

      admin? ->
        {:error, Error.new(:not_found, %{team: name, reason: "there is no team #{name}"})}

      true ->
        {:error, Error.new(:forbidden, %{team: name, reason: not_in_team(name, teams)})}
    end
  end

  # Its owner's alone, until they share it with a link.
  defp may_publish(user, "private", _admin?), do: covered(user)

  defp may_publish(user, "profile:" <> name, _admin?) do
    if name in profiles_of(user),
      do: :ok,
      else:
        {:error,
         Error.new(:forbidden, %{
           reason: "you are not among profile #{name}'s people, so you cannot publish to them"
         })}
  end

  defp not_in_team(name, []),
    do: "you are not in team #{name}, so you cannot publish to its people; you are in no team"

  defp not_in_team(name, teams),
    do:
      "you are not in team #{name}, so you cannot publish to its people; you are in " <>
        Enum.map_join(teams, ", ", &"team:#{&1}")

  # The teams `user` is in, by name, read now: a team's members are its groups' members.
  defp teams_of(user), do: user |> Identity.teams_for() |> Enum.map(& &1.name)

  # The teams `user` administers, by name: theirs to take a team's artifact down. A
  # principal administers nothing.
  defp administered_by(%User{kind: "service"}), do: []

  defp administered_by(%User{} = user),
    do: user |> Identity.teams_administered_by() |> Enum.map(& &1.name)

  # Whether `user` administers the team an artifact is for, from `administered` where a
  # list read it once.
  defp administers?(artifact, user, administered \\ nil)

  defp administers?(%Artifact{visibility: "team:" <> name}, user, administered),
    do: name in (administered || administered_by(user))

  defp administers?(_artifact, _user, _administered), do: false

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
        {:cont, {:ok, [stored(path, body, type) | acc], total, MapSet.put(seen, path)}}
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

  defp stored(path, body, type),
    do: %{path: path, body: body, content_type: type, sha256: sha256(body), bytes: byte_size(body)}

  # One file that came by an upload handle, held to what a file sent inline is held to.
  defp checked_file(path, body, type) do
    with {:ok, path} <- path(%{"path" => path}),
         :ok <- within_file(path, body),
         {:ok, type} <- content_type(%{"content_type" => type}, path) do
      {:ok, stored(path, body, type)}
    end
  end

  @doc """
  A path as an artifact keeps it, or why it is refused: relative, `/`-separated, no empty,
  `.` or `..` segment nor one past 255 bytes, and not starting with a segment the host's addresses take (`v<n>`).
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
      # The object store's own limit on one part of a key, said before anything is written.
      {&Enum.any?(String.split(&1, "/"), fn part -> byte_size(part) > @max_segment end),
       fn _ -> "each part of a path between its / is at most #{@max_segment} bytes" end},
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
      {:ok, body} ->
        with :ok <- within_file(path, body), do: {:ok, body}

      :error ->
        {:error, invalid("#{path}'s bytes are not base64")}
    end
  end

  defp body(_file, path), do: {:error, invalid("#{path} has no bytes (base64)")}

  defp within_file(path, %{size: size}) when size > @max_file_bytes,
    do:
      {:error,
       Error.new(:payload_too_large, %{
         path: path,
         limit: @max_file_bytes,
         reason: "#{path} is #{size} bytes, past the #{@max_file_bytes} a file may be"
       })}

  defp within_file(_path, %{size: size}), do: {:ok, size}

  defp within_file(path, body) when is_binary(body) do
    with {:ok, _size} <- within_file(path, %{size: byte_size(body)}), do: :ok
  end

  @doc false
  def within_version(total) when total > @max_version_bytes,
    do:
      {:error,
       Error.new(:payload_too_large, %{
         limit: @max_version_bytes,
         reason: "a version is at most #{@max_version_bytes} bytes"
       })}

  def within_version(_total), do: :ok

  @doc false
  def content_type(%{"content_type" => type}, _path) when is_binary(type) and type != "" do
    if type =~
         ~r{\A[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]*(\s*;\s*charset=[A-Za-z0-9_-]+)?\z},
       do: {:ok, String.downcase(type)},
       else: {:error, invalid("#{inspect(type)} is not a content type")}
  end

  def content_type(_file, path), do: {:ok, MIME.from_path(path)}

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

  # Which team's quota the bytes count against: the team it is for; else the pod session's
  # team; else the team that grants the profile it is for; else the publisher's first team.
  # Nobody in no team publishes.
  defp team_for(_user, "team:" <> name, _session) do
    case Identity.get_team(name) do
      %Identity.Team{id: id} -> {:ok, id}
      nil -> {:error, Error.new(:not_found, %{team: name, reason: "there is no team #{name}"})}
    end
  end

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

  # The first of their teams by name, so the same one every time.
  defp first_team(user) do
    case Identity.teams_for(user) do
      [team | _] -> team.id
      [] -> nil
    end
  end

  # One `user` may put a new version of: their own, or one they hold an edit link to; and
  # which of the two it is.
  defp editable(id, user, admin?) when is_binary(id) do
    with {:ok, artifact} <- visible(id, user, admin?) do
      case role(artifact, user) do
        role when role in ["owner", "edit"] ->
          {:ok, artifact, role}

        _view ->
          {:error,
           Error.new(:forbidden, %{
             id: id,
             reason:
               "only its owner, or somebody the owner gave an edit link, publishes a new version of an artifact"
           })}
      end
    end
  end

  defp editable(other, _user, _admin?),
    do: {:error, invalid("id is an artifact's id, not #{inspect(other)}")}

  # One that is `user`'s own: what only an owner does to it, in `what` words.
  defp owned(id, user, admin?, what) when is_binary(id) do
    with {:ok, artifact} <- visible(id, user, admin?) do
      if role(artifact, user) == "owner",
        do: {:ok, artifact},
        else: {:error, Error.new(:forbidden, %{id: id, reason: "only its owner #{what} an artifact"})}
    end
  end

  defp owned(other, _user, _admin?, _what),
    do: {:error, invalid("id is an artifact's id, not #{inspect(other)}")}

  defp same_kind(_artifact, nil), do: :ok
  defp same_kind(%Artifact{kind: kind}, kind), do: :ok

  defp same_kind(%Artifact{kind: kind}, _other),
    do:
      {:error,
       invalid("this artifact is #{kind}; an artifact keeps its kind, so publish another one")}

  # Who may open it moves only by its owner's hand, and only to where they may publish.
  defp may_move(%Artifact{visibility: visibility}, visibility, _role, _user, _admin?), do: :ok
  defp may_move(_artifact, visibility, "owner", user, admin?), do: may_publish(user, visibility, admin?)

  defp may_move(artifact, _visibility, _role, _user, _admin?),
    do:
      {:error,
       Error.new(:forbidden, %{
         id: artifact.id,
         reason: "who may open an artifact is its owner's to change; an edit link publishes versions of it"
       })}

  defp note(nil), do: {:ok, nil}

  defp note(note) when is_binary(note) do
    note = note |> String.split() |> Enum.join(" ")

    cond do
      note == "" -> {:ok, nil}
      String.length(note) > @max_note -> {:error, invalid("a note is at most #{@max_note} characters")}
      true -> {:ok, note}
    end
  end

  defp note(other), do: {:error, invalid("a note is text, not #{inspect(other)}")}

  # The version an edit was made on. It must still be the newest: one published since would
  # be lost under it without its editor knowing.
  defp base(_artifact, nil), do: {:ok, nil}

  defp base(%Artifact{version: newest} = artifact, n) when is_integer(n) do
    cond do
      n == newest ->
        {:ok, version_of(artifact, n)}

      n > 0 and n < newest ->
        {:error,
         Error.new(:conflict, %{
           id: artifact.id,
           base: n,
           newest: newest,
           reason:
             "version #{newest} was published after version #{n}, which this edit was made on; " <>
               "open version #{newest} and make the edit again"
         })}

      true ->
        {:error, Error.new(:not_found, %{id: artifact.id, version: n})}
    end
  end

  defp base(_artifact, other),
    do: {:error, invalid("base is the version an edit was made on, not #{inspect(other)}")}

  # The files sent, and the base's files not among them as the base keeps them.
  defp carry(nil, sent), do: sent

  defp carry(%Version{} = base, sent) do
    paths = MapSet.new(sent, & &1.path)

    base.files
    |> Enum.reject(&MapSet.member?(paths, &1["path"]))
    |> Enum.map(&carried(&1, base.n))
    |> Kernel.++(sent)
    |> Enum.sort_by(& &1.path)
  end

  # A file of version `n` in a later version: its object stays where it is.
  defp carried(file, n) do
    %{
      path: file["path"],
      content_type: file["content_type"],
      sha256: file["sha256"],
      bytes: file["bytes"],
      stored_in: file["stored_in"] || n
    }
  end

  # The files a call carries: inline, or in the object store under an upload handle.
  defp incoming(%{"upload" => handle}, user) when is_binary(handle),
    do: Uploads.take(handle, user, store(), &checked_file/3)

  defp incoming(params, _user), do: files(params["files"])

  # Over a base, a put may send no files at all: every one of the base's is carried, which
  # is how its owner moves who may open it, or retitles it, without sending it again.
  defp incoming_over(%Version{}, params, _user) when not is_map_key(params, "files") and not is_map_key(params, "upload"),
    do: {:ok, []}

  defp incoming_over(_base, params, user), do: incoming(params, user)

  # The team a new version counts against: the team it is for, where it is a team's, which
  # takes every byte of it there; else the artifact's, while there is one.
  defp team_of(_artifact, user, "team:" <> _ = visibility, session),
    do: team_for(user, visibility, session)

  defp team_of(%Artifact{team_id: team_id}, _user, _visibility, _session) when is_binary(team_id),
    do: {:ok, team_id}

  defp team_of(_artifact, user, visibility, session), do: team_for(user, visibility, session)

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

  # One version written: its new files into the object store, its row, the artifact's, and
  # the audit. A version that is not written leaves no object behind: what was put before the
  # refusal or the failure is taken back.
  defp write(user, existing, attrs) do
    bytes = attrs.files |> Enum.map(& &1.bytes) |> Enum.sum()
    new_bytes = attrs.files |> Enum.filter(&Map.has_key?(&1, :body)) |> Enum.map(& &1.bytes) |> Enum.sum()
    moved = moved_bytes(existing, attrs.team_id)
    hash = version_hash(attrs.files)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      artifact = lock(existing) || new_artifact(user, attrs, now)
      n = (existing && artifact.version + 1) || 1

      with :ok <- republishable(existing, attrs),
           :ok <- within_version(bytes),
           :ok <- within_quota(attrs.team_id, new_bytes + moved, existing),
           :ok <- put_objects(artifact.id, n, attrs.files) do
        try do
          Repo.insert!(%Version{
            artifact_id: artifact.id,
            n: n,
            hash: hash,
            bytes: bytes,
            files: Enum.map(attrs.files, &file_json/1),
            published_by: user.subject,
            published_at: now,
            note: attrs[:note],
            rolled_back_to: attrs[:rolled_back_to]
          })

          artifact =
            artifact
            |> Ecto.Changeset.change(%{
              title: attrs.title,
              visibility: attrs.visibility,
              team_id: attrs.team_id,
              version: n,
              bytes: if(artifact.pinned, do: artifact.bytes, else: bytes),
              total_bytes: artifact.total_bytes + new_bytes,
              updated_at: now
            })
            |> Repo.update!()

          {action, detail} = audit_detail(artifact, existing, n, hash, bytes, attrs)
          {:ok, _event} = Audit.record(user.subject, action, artifact.id, detail)
          artifact
        rescue
          exception ->
            take_back(artifact.id, n, attrs.files)
            reraise exception, __STACKTRACE__
        end
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      {:ok, artifact} -> {:ok, answer(artifact, user, false)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # An artifact moved to another team takes what it already holds to that team's quota.
  defp moved_bytes(%Artifact{team_id: from, total_bytes: bytes}, to) when from != to, do: bytes
  defp moved_bytes(_existing, _team_id), do: 0

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

  # The files a version brings, into the object store; a file it carries from an earlier
  # version is that version's object already. One the store refuses takes back the ones it
  # took before it, so a refused version leaves nothing.
  defp put_objects(id, n, files) do
    store = store()

    files
    |> Enum.filter(&Map.has_key?(&1, :body))
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, put} ->
      case ObjectStore.put(store, key(id, n, file.path), file.body,
             content_type: file.content_type
           ) do
        {:ok, _put} ->
          {:cont, {:ok, [file | put]}}

        {:error, reason} ->
          take_back(id, n, put)

          {:halt,
           {:error,
            Error.new(:unavailable, %{
              reason: "the object store refused #{file.path}: #{inspect(reason)}"
            })}}
      end
    end)
    |> case do
      {:ok, _put} -> :ok
      error -> error
    end
  end

  defp take_back(id, n, files) do
    store = store()

    for %{body: _} = file <- files,
        do: ObjectStore.delete(store, key(id, n, file.path))

    :ok
  end

  defp audit_detail(artifact, existing, n, hash, bytes, attrs) do
    detail =
      %{
        "version" => n,
        "title" => artifact.title,
        "kind" => artifact.kind,
        "visibility" => artifact.visibility,
        "bytes" => bytes,
        "hash" => hash,
        "note" => attrs[:note],
        "session" => artifact.origin["session_id"],
        "agent" => artifact.origin["agent"],
        # A version put by somebody else than its owner, through their edit link.
        "by" => if(attrs[:role] == "edit", do: "edit link")
      }
      |> then(fn detail ->
        if existing && existing.visibility != artifact.visibility,
          do: Map.put(detail, "visibility_from", existing.visibility),
          else: detail
      end)

    case attrs[:rolled_back_to] do
      nil -> {"artifact.publish", compact(detail)}
      to -> {"artifact.rollback", detail |> Map.put("rolled_back_to", to) |> compact()}
    end
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp file_json(file) do
    %{
      "path" => file.path,
      "sha256" => file.sha256,
      "content_type" => file.content_type,
      "bytes" => file.bytes
    }
    |> then(&if(file[:stored_in], do: Map.put(&1, "stored_in", file.stored_in), else: &1))
  end

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

  @doc """
  What `user` may see, newest published first, narrowed by `mine`, `shared` (the ones a link
  gave them), `teams` (the teams' own) or `visibility`. Each row says its `scope`, the
  gallery tab it is under.
  """
  @spec list(User.t(), map(), keyword()) :: {:ok, map()}
  def list(%User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    audience = %{
      profiles: profiles_of(user),
      teams: teams_of(user),
      administered: administered_by(user)
    }

    artifacts =
      if enabled?() do
        user
        |> visible_query(audience, admin?)
        |> narrow(params, user, admin? || audience)
        |> order_by([a], desc: a.updated_at)
        |> limit(500)
        |> preload([:owner, :team])
        |> Repo.all()
        |> with_roles(user, audience)
        |> Enum.map(fn {artifact, meta} -> to_json(artifact, user, admin?, meta) end)
      else
        []
      end

    {:ok,
     %{
       "enabled" => enabled?(),
       "profiles" => audience.profiles,
       "teams" => audience.teams,
       "publish_organisation" =>
         to_string(Settings.get("artifacts_publish_organisation") || :everyone),
       "public_links" => Shares.public_links?(),
       "gallery_url" => console_url() && console_url() <> "#/artifacts",
       "artifacts" => artifacts
     }}
  end

  # A platform administrator sees every one but another person's private ones; anybody else
  # their own, those a link gave them, and those for somebody they are: the organisation, a
  # profile they are granted, a team they are in or administer.
  defp visible_query(user, _audience, true) do
    owner = user.id

    if is_binary(owner) do
      shared = Shares.shared_with(user)

      from(a in Artifact,
        where: a.visibility != "private" or a.owner_id == ^owner or a.id in subquery(shared)
      )
    else
      from(a in Artifact, where: a.visibility != "private")
    end
  end

  defp visible_query(user, audience, false) do
    visibilities =
      ["organisation"] ++
        Enum.map(audience.profiles, &"profile:#{&1}") ++
        Enum.map(Enum.uniq(audience.teams ++ audience.administered), &"team:#{&1}")

    owner = user.id

    if is_binary(owner) do
      shared = Shares.shared_with(user)

      from(a in Artifact,
        where: a.owner_id == ^owner or a.visibility in ^visibilities or a.id in subquery(shared)
      )
    else
      from(a in Artifact, where: a.visibility in ^visibilities)
    end
  end

  # The teams' own: every team's for a platform administrator (`true`), else those of the
  # teams the caller is in or administers, and not one a link alone reached, which is shared.
  defp narrow(query, %{"teams" => true}, _user, true),
    do: where(query, [a], like(a.visibility, "team:%"))

  defp narrow(query, %{"teams" => true}, _user, audience) do
    teams = Enum.map(Enum.uniq(audience.teams ++ audience.administered), &"team:#{&1}")
    where(query, [a], a.visibility in ^teams)
  end

  defp narrow(query, params, user, _audience), do: narrow(query, params, user)

  defp narrow(query, %{"mine" => true}, %User{id: id}) when is_binary(id),
    do: where(query, [a], a.owner_id == ^id)

  defp narrow(query, %{"mine" => true}, _user), do: where(query, [a], false)

  defp narrow(query, %{"shared" => true}, %User{id: id} = user) when is_binary(id) do
    shared = Shares.shared_with(user)
    where(query, [a], a.id in subquery(shared) and (is_nil(a.owner_id) or a.owner_id != ^id))
  end

  defp narrow(query, %{"shared" => true}, _user), do: where(query, [a], false)

  defp narrow(query, %{"visibility" => visibility}, _user) when is_binary(visibility),
    do: where(query, [a], a.visibility == ^visibility)

  defp narrow(query, _params, _user), do: query

  @doc "One artifact with its versions, if `user` may see it."
  @spec get(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- visible(id, user, admin?) do
      artifact = artifact |> Repo.preload([:owner, :team, :versions])
      json = to_json(artifact, user, admin?, meta_of(artifact, user))

      # Who holds a link to it is the owner's to read, and whether a public one may be made.
      if json["role"] == "owner",
        do:
          {:ok,
           Map.merge(json, %{
             "shares" => Shares.list(artifact),
             "public_links_allowed" => Shares.public_links?()
           })},
        else: {:ok, json}
    end
  end

  @doc """
  The artifact `id` if `user` may see it, read now. `not_found` for one they may not, as for
  one that is not there, and for every one while artifacts are off. A platform administrator
  sees every one but another person's private ones, and a team's administrator their team's.
  """
  @spec visible(term(), User.t(), boolean()) :: {:ok, Artifact.t()} | {:error, Error.t()}
  def visible(id, %User{} = user, admin?) when is_binary(id) do
    with true <- enabled?(),
         %Artifact{} = artifact <- Repo.get(Artifact, id),
         true <-
           (admin? and artifact.visibility != "private") or sees?(artifact, user) or
             administers?(artifact, user) do
      {:ok, artifact}
    else
      _no -> {:error, Error.new(:not_found, %{id: id})}
    end
  end

  def visible(id, _user, _admin?), do: {:error, Error.new(:not_found, %{id: id})}

  # What a takedown finds: what `user` sees, and for a platform administrator every one, a
  # private one too, which is the only thing anybody but its owner and its links' holders
  # may do to one.
  defp findable(id, _user, true) when is_binary(id) do
    with true <- enabled?(),
         %Artifact{} = artifact <- Repo.get(Artifact, id) do
      {:ok, artifact}
    else
      _no -> {:error, Error.new(:not_found, %{id: id})}
    end
  end

  defp findable(id, user, false), do: visible(id, user, false)
  defp findable(id, _user, _admin?), do: {:error, Error.new(:not_found, %{id: id})}

  defp sees?(artifact, user), do: role(artifact, user) != nil

  @doc """
  What `user` is to `artifact` now: `owner`; `edit` or `view` through a link of the owner's
  they were signed in through, while it lasts; `view` through who it is for; or `nil`.
  """
  @spec role(Artifact.t(), User.t()) :: String.t() | nil
  def role(%Artifact{owner_id: owner}, %User{id: owner}) when is_binary(owner), do: "owner"

  def role(%Artifact{} = artifact, %User{} = user) do
    case Shares.role(artifact, user) do
      "edit" -> "edit"
      linked -> if(linked == "view" or for?(artifact, user), do: "view")
    end
  end

  # Whether an artifact is for somebody `user` is, from `audience` where a list read what
  # they are in once. A private one is for nobody but its owner.
  defp for?(artifact, user, audience \\ nil)
  defp for?(%Artifact{visibility: "organisation"}, user, _audience), do: covered(user) == :ok

  defp for?(%Artifact{visibility: "profile:" <> name}, user, audience),
    do: name in ((audience && audience.profiles) || profiles_of(user))

  defp for?(%Artifact{visibility: "team:" <> name}, user, audience),
    do: name in ((audience && audience.teams) || teams_of(user))

  defp for?(_artifact, _user, _audience), do: false

  # A list's roles in one query for its links, rather than one per artifact.
  defp with_roles(artifacts, user, audience) do
    linked = Shares.roles(Enum.map(artifacts, & &1.id), user)
    public = Shares.public_ids(Enum.map(artifacts, & &1.id))

    Enum.map(artifacts, fn artifact ->
      for? = for?(artifact, user, audience)
      link = linked[artifact.id]

      role =
        cond do
          is_binary(artifact.owner_id) and artifact.owner_id == user.id -> "owner"
          link == "edit" -> "edit"
          link == "view" or for? -> "view"
          true -> nil
        end

      {artifact,
       %{
         role: role,
         public: MapSet.member?(public, artifact.id),
         scope: scope(artifact, role, for?, link),
         administers: administers?(artifact, user, audience.administered)
       }}
    end)
  end

  defp meta_of(artifact, user) do
    role = role(artifact, user)
    for? = for?(artifact, user)
    # Not its owner's and not for them, a role is a link's.
    link = if role in ["view", "edit"] and not for?, do: role

    %{
      role: role,
      public: MapSet.member?(Shares.public_ids([artifact.id]), artifact.id),
      scope: scope(artifact, role, for?, link),
      administers: administers?(artifact, user)
    }
  end

  # The gallery tab a row is under: the caller's own (`private` for the ones only they
  # open); who it is for, where that takes the caller in; `shared` where only a link does;
  # else who it is for, as an administrator sees it.
  defp scope(%Artifact{visibility: "private"}, "owner", _for?, _link), do: "private"
  defp scope(_artifact, "owner", _for?, _link), do: "mine"
  defp scope(artifact, _role, true, _link), do: artifact.visibility
  defp scope(_artifact, _role, false, link) when link in ["view", "edit"], do: "shared"
  defp scope(artifact, _role, _for?, _link), do: artifact.visibility

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
         {:ok, file, body} <- file_of(artifact, found, path) do
      {:ok, %{artifact: artifact, version: found, file: file, body: body}}
    else
      _no -> {:error, :not_found}
    end
  end

  @doc false
  # One file of a version and its bytes, where the version keeps them: under its own `n`, or
  # under the earlier version's it carried the file from.
  def file_of(%Artifact{} = artifact, %Version{} = version, path) do
    with %{} = file <- Enum.find(version.files, &(&1["path"] == path)),
         {:ok, body} <- ObjectStore.get(store(), key(artifact.id, file["stored_in"] || version.n, path)) do
      {:ok, file, body}
    else
      _no -> :error
    end
  end

  @doc false
  def entry_path(artifact, version, path), do: file_path(artifact, version, path)

  @doc "The version an artifact's address serves: the one its owner pinned, else the newest."
  @spec current(Artifact.t()) :: pos_integer()
  def current(%Artifact{pinned: pinned}) when is_integer(pinned), do: pinned
  def current(%Artifact{version: n}), do: n

  defp version_of(%Artifact{} = artifact, :current),
    do: Repo.get_by(Version, artifact_id: artifact.id, n: current(artifact))

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
  Delete an artifact, every version and every byte: its owner's, or a takedown by a platform
  administrator (any, a private one too) or by the administrator of the team it is for.
  Audited as `artifact.delete` with which it was.
  """
  @spec delete(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- findable(id, user, admin?),
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

  defp deleter(artifact, user, false) do
    if administers?(artifact, user),
      do: {:ok, "takedown"},
      else:
        {:error,
         Error.new(:forbidden, %{
           id: artifact.id,
           reason:
             "only its owner, a platform administrator, or the administrator of the team it is for deletes an artifact"
         })}
  end

  # -- the administrators' table ------------------------------------------------------

  @doc """
  What `Admin.artifacts_list/1` lists, newest published first: `:all` for a platform
  administrator, every one, private ones too, since a takedown is theirs; or the names of
  the teams a team administrator answers for, those teams' own. Titles, owners, teams and
  sizes, never what one holds. Nothing while artifacts are off.
  """
  @spec admin_list(:all | [String.t()]) :: [map()]
  def admin_list(teams) do
    query =
      case teams do
        :all -> from(a in Artifact)
        names -> from(a in Artifact, where: a.visibility in ^Enum.map(names, &"team:#{&1}"))
      end

    if enabled?() do
      query
      |> order_by([a], desc: a.updated_at)
      |> limit(500)
      |> preload([:owner, :team])
      |> Repo.all()
      |> Enum.map(&admin_row/1)
    else
      []
    end
  end

  defp admin_row(artifact) do
    %{
      "id" => artifact.id,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      "owner" => person(artifact.owner),
      "team" => team_name(artifact.team),
      "origin" => Map.merge(%{"profile" => artifact.profile}, artifact.origin || %{}),
      "version" => artifact.version,
      "bytes" => artifact.bytes,
      "total_bytes" => artifact.total_bytes,
      "created_at" => artifact.inserted_at,
      "published_at" => artifact.updated_at,
      "may_take_down" => true
    }
  end

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

  # -- editing in the console -------------------------------------------------------

  # What the console's editor opens: text, and no more than a person edits by hand.
  @max_read 1024 * 1024

  @doc """
  One text file of a version, for the console's editor: `path`, its `content_type`, its
  `text`, and the `version` it is of (`nil` for the current one). Whoever may see it reads
  it; a file that is not UTF-8 text, or past a mebibyte, is not one to edit here.
  """
  @spec read(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read(id, %User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)
    n = params["version"]

    with {:ok, artifact} <- visible(id, user, admin?),
         %Version{} = version <- version_of(artifact, if(is_integer(n), do: n, else: :current)),
         {:ok, path} <- file_path(artifact, version, params["path"]),
         {:ok, file, body} <- file_of(artifact, version, path) do
      cond do
        byte_size(body) > @max_read ->
          {:error, invalid("#{path} is #{byte_size(body)} bytes, more than the editor opens")}

        not String.valid?(body) ->
          {:error, invalid("#{path} is not text, so it is not one to edit here")}

        true ->
          {:ok,
           %{
             "id" => artifact.id,
             "version" => version.n,
             "path" => path,
             "content_type" => file["content_type"],
             "text" => body
           }}
      end
    else
      {:error, %Error{}} = error -> error
      _no -> {:error, Error.new(:not_found, %{id: id, path: params["path"]})}
    end
  end

  @doc """
  An edit's preview on the artifacts host: `text` as `path` over version `base` (the
  current one if none), served from `/p/<nonce>/` for an hour with the version's other
  files, so the console frames the artifact as it would be and never draws it itself.
  Whoever may put; nothing is published.
  """
  @spec preview(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def preview(id, %User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact, _role} <- editable(id, user, admin?),
         %Version{} = base <- version_of(artifact, preview_base(params["base"])),
         {:ok, path} <- path(%{"path" => params["path"]}),
         {:ok, text} <- preview_text(params["text"], path),
         {:ok, type} <- content_type(%{"content_type" => params["content_type"]}, path),
         host when is_binary(host) <- host_url() || {:error, no_host()} do
      nonce = Previews.put(artifact.id, user.subject, base.n, path, type, text)
      {:ok, %{"url" => "#{host}/p/#{nonce}/", "expires_in" => Previews.seconds()}}
    else
      nil -> {:error, Error.new(:not_found, %{id: id, version: params["base"]})}
      {:error, _} = error -> error
    end
  end

  defp preview_base(n) when is_integer(n), do: n
  defp preview_base(_none), do: :current

  defp preview_text(text, path) when is_binary(text) do
    if byte_size(text) > @max_read,
      do: {:error, invalid("#{path} is more than the editor previews")},
      else: {:ok, text}
  end

  defp preview_text(_text, _path), do: {:error, invalid("a preview needs the file's text")}

  @doc """
  One file of a preview for the artifacts host, `nil` for its entry: the edited file, or the
  version's own. `:error` for one that is not there, is past its hour, or whose person may
  no longer put to the artifact.
  """
  @spec preview_file(String.t(), String.t() | nil) :: {:ok, map()} | :error
  def preview_file(nonce, path) do
    with true <- enabled?(),
         {:ok, preview} <- Previews.get(nonce),
         %User{} = user <- Identity.get_user(preview.subject),
         true <- user.active != false,
         %Artifact{} = artifact <- Repo.get(Artifact, preview.artifact_id),
         role when role in ["owner", "edit"] <- role(artifact, user),
         %Version{} = base <- version_of(artifact, preview.base) do
      edited = %{"path" => preview.path, "content_type" => preview.content_type}
      draft = %Version{base | files: [edited | Enum.reject(base.files, &(&1["path"] == preview.path))]}

      with {:ok, path} <- file_path(artifact, draft, path),
           {:ok, file, body} <- draft_file(artifact, base, preview, edited, path) do
        {:ok, %{artifact: artifact, version: draft, file: file, body: body}}
      end
    else
      _no -> :error
    end
  end

  # The edited file is the preview's own; every other is the base version's.
  defp draft_file(_artifact, _base, %{path: path} = preview, edited, path),
    do: {:ok, edited, preview.body}

  defp draft_file(artifact, base, _preview, _edited, path), do: file_of(artifact, base, path)

  # -- links ------------------------------------------------------------------------

  @doc """
  A link to artifact `id` (`Shares.share/3`): the owner's, with `role` `view` or `edit`,
  `expires`, and `public` for one that needs no sign-in, where an administrator allows them.
  """
  @spec share(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def share(id, %User{} = user, params, opts \\ []) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "shares"),
         host when is_binary(host) <- host_url() || {:error, no_host()} do
      Shares.share(artifact, user, params, host)
    end
  end

  @doc "Revoke a link (`share`, its id) or one person's use of every link (`person`, a subject)."
  @spec unshare(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def unshare(id, %User{} = user, params, opts \\ []) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "revokes a link to") do
      Shares.unshare(artifact, user, params)
    end
  end

  @doc """
  A link's token, spent by the person the plane signed in: they hold its role on the
  artifact from now while the link lasts, and are answered a ticket that opens it.
  """
  @spec redeem_link(String.t(), User.t()) :: {:ok, map()} | {:error, Error.t()}
  def redeem_link(token, %User{} = user) do
    with :ok <- on(),
         {:ok, artifact_id, role} <- Shares.use(token, user),
         {:ok, %{"url" => url}} <- ticket(artifact_id, user) do
      {:ok, %{"id" => artifact_id, "role" => role, "url" => url}}
    end
  end

  @doc """
  A link's token, spent by the viewer the artifacts host's own cookie names: the artifact's
  id, which the host then opens, or `:error`.
  """
  @spec use_link(String.t(), User.t()) :: {:ok, String.t()} | :error
  def use_link(token, %User{} = user) do
    with true <- enabled?(),
         {:ok, artifact_id, _role} <- Shares.use(token, user) do
      {:ok, artifact_id}
    else
      _no -> :error
    end
  end

  @doc "Whether `token` is a link that still opens something, public or not."
  @spec link?(String.t()) :: {:ok, :public | :signed_in} | :error
  def link?(token), do: if(enabled?(), do: Shares.live(token), else: :error)

  @doc """
  One file of the artifact a public link opens, `nil` for its entry, for whoever has the
  link: only while the administrator's `artifacts_public_links` and the artifact's own
  switch are both on, and the link has not expired or been revoked.
  """
  @spec public(String.t(), String.t() | nil) :: {:ok, map()} | :error
  def public(token, path) do
    with true <- enabled?(),
         {:ok, artifact} <- Shares.public_artifact(token),
         true <- artifact.public_links != false,
         %Version{} = version <- version_of(artifact, :current),
         {:ok, path} <- file_path(artifact, version, path),
         {:ok, file, body} <- file_of(artifact, version, path) do
      {:ok, %{artifact: artifact, version: version, file: file, body: body}}
    else
      _no -> :error
    end
  end

  # -- an upload handle ------------------------------------------------------------

  @doc """
  An upload handle for a version too large for one call: each file `{path, size,
  content_type?}` gets a URL that takes its bytes straight into the object store, and a
  publish or a put then names the handle as `upload` instead of sending `files`.
  """
  @spec begin_upload(User.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def begin_upload(%User{} = user, params) do
    with :ok <- on(),
         {:ok, files} <- announced(params["files"]) do
      Uploads.begin(user, files, store())
    end
  end

  defp announced(files) when is_list(files) and files != [] and length(files) <= @max_files do
    files
    |> Enum.reduce_while({:ok, [], 0, MapSet.new()}, fn file, {:ok, acc, total, seen} ->
      with {:ok, path} <- path(file),
           :ok <- unseen(path, seen),
           {:ok, size} <- size(file, path),
           {:ok, type} <- content_type(file, path),
           total = total + size,
           :ok <- within_version(total) do
        {:cont, {:ok, [%{"path" => path, "size" => size, "content_type" => type} | acc], total, MapSet.put(seen, path)}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, files, _total, _seen} -> {:ok, Enum.sort_by(files, & &1["path"])}
      error -> error
    end
  end

  defp announced(files) when is_list(files) and length(files) > @max_files,
    do: {:error, invalid("an artifact has at most #{@max_files} files")}

  defp announced(_files),
    do: {:error, invalid("an upload names its files: [{path, size, content_type?}]")}

  defp size(%{"size" => size}, path) when is_integer(size) and size >= 0,
    do: within_file(path, %{size: size})

  defp size(_file, path), do: {:error, invalid("#{path} needs its size in bytes")}

  defp no_host,
    do: Error.new(:unavailable, %{reason: "this plane was deployed without an artifacts host (plane.artifactsHost)"})

  @doc """
  The console's address on the plane, where a viewer is signed in and an artifact opened
  again, or `nil` where the plane has no address of its own.
  """
  @spec console_url() :: String.t() | nil
  def console_url do
    case Application.get_env(:troupe_plane, :base_url) do
      base when is_binary(base) and base != "" ->
        path =
          case Application.get_env(:troupe_plane, :console_url, "/console") do
            "" -> "/console"
            url -> url
          end

        URI.to_string(URI.merge(String.trim_trailing(base, "/") <> "/", path))

      _none ->
        nil
    end
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
  @spec to_json(Artifact.t(), User.t(), boolean(), map() | nil) :: map()
  def to_json(%Artifact{} = artifact, %User{} = user, admin?, meta \\ nil) do
    meta = meta || meta_of(artifact, user)
    mine = meta.role == "owner"

    %{
      "id" => artifact.id,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      # The gallery tab it is under: mine, private, organisation, team:<name>,
      # profile:<name> or shared.
      "scope" => meta.scope,
      "owner" => person(artifact.owner),
      "mine" => mine,
      "role" => meta.role,
      "origin" => Map.merge(%{"profile" => artifact.profile}, artifact.origin || %{}),
      "team" => team_name(artifact.team),
      "version" => artifact.version,
      "current" => current(artifact),
      "pinned" => artifact.pinned,
      "bytes" => artifact.bytes,
      "url" => url(artifact.id),
      "created_at" => artifact.inserted_at,
      "published_at" => artifact.updated_at,
      "may_delete" => mine or admin? or meta.administers,
      "may_edit" => meta.role in ["owner", "edit"],
      # The owner's switch for its public links, and whether one opens now.
      "public_links" => artifact.public_links != false,
      "public" => meta.public
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
          "files" => Enum.map(version.files, &Map.delete(&1, "stored_in")),
          "published_by" =>
            Map.get(people, version.published_by, %{
              "subject" => version.published_by,
              "display_name" => nil
            }),
          "published_at" => version.published_at,
          "note" => version.note,
          "rolled_back_to" => version.rolled_back_to,
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
