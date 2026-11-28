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

  **Whose it is.** The person who published it, or a team (`owner_team`): then every
  member and administrator of that team is its owner, with everything an owner does, and a
  person leaving the team changes nothing for the artifact. A new one is its publisher's
  unless they say `owner: "team"` (the one team it is read by) or `owner: "team:<name>"`;
  who reads it does not decide whose it is. A person gives their own to a team they are in
  with `transfer/4`, and an administrator of the owning team, or a platform administrator,
  takes it back, which makes them its person. The person who published it stays on the
  row, and a team that is deleted hands its artifacts back to each one's person. Who
  published each version is the version's own record.

  **Who reads it.** A set, kept across its versions: its owners; the teams it is given to
  (`Teams`), whose members open it; the people it is shared with by name (`People`); every
  signed-in person, while `visibility` is `organisation`; and whoever a link of an owner's
  gave it to (`Shares`). `private`, the default, is that set without the organisation. A
  platform administrator sees every one but a person's own that no team or organisation
  reads, and a team's administrator those their teams read, since taking one down is
  theirs. Anybody else is told there is no such artifact, as for one that does not exist.
  The set is read again at every request, the artifacts host's included, so a person who
  leaves a team stops seeing what it reads at their next request. An owner changes the set
  with `set_access/4` and reads it whole with `access/3`; a new version changes nothing of it.

  **Who publishes it.** Anybody signed in, for themselves, giving it to the teams they are in
  and the teams granted the profile its session ran on (a platform administrator to any
  team); for the organisation, anybody or only platform administrators as
  `artifacts_publish_organisation` says. Only an owner republishes or deletes one, or an
  edit grant's holder republishes it; a platform administrator takes any down, a private one
  too, and a team's administrator those their team reads or owns. Its bytes count against
  the quota of the team that owns it, else the pod session's team, else its publisher's
  first. Every publish, republish, change of readers, transfer and delete is in the audit
  trail with who did it and the session it came from; never the content.

  **What it may hold.** A file is at most 16 MiB and a version 64 MiB, and a team's artifacts
  together at most its `artifact_quota_bytes`, every version counted (zero is no quota). What
  one call can carry is less than that: the door's own limit on a body. A version may come
  with a picture of itself for its gallery card (`thumbnail`, a PNG, JPEG or WebP of at most
  256 KiB), kept beside its files and counted as one; the plane draws none itself. Each
  HTML, CSS and JavaScript file, and each Markdown document of a Markdown artifact, is read
  at publish for what the artifacts host's policy will block (`Blocked`): the publish still
  succeeds, and its answer, the version and the rows say what was found.

  **How long it is kept.** Until an owner deletes it or an administrator takes it down,
  unless an administrator sets a retention period: then old versions, or artifacts nobody
  opens, are removed by `Retention`'s hourly pass, and every row says when it goes (`goes_at`).

  **Where it is read.** Never on the plane's host. The artifacts host
  (`Troupe.Plane.Web.Artifacts`) serves it, on an origin of its own, to a viewer who came
  through a ticket this module signs (`ticket/3`) and holds the cookie that host set.
  """

  import Ecto.Query

  alias Troupe.ObjectStore
  alias Troupe.Plane.{Admin, Audit, Identity, Repo, Settings}
  alias Troupe.Plane.Artifacts.{Artifact, Blocked, Comments, Keeps, Markdown, People, Previews}
  alias Troupe.Plane.Artifacts.{Retention, Shares, Teams, Uploads, Version}
  alias Troupe.Plane.Identity.User
  alias Troupe.Plane.Sessions.{Sensitive, Session}
  alias Troupe.Protocol.Digest
  alias Troupe.Protocol.Error
  alias Troupe.Protocol.Words

  @kinds ~w(html markdown file)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024
  @max_files 500
  @max_title 200
  @max_path 512
  @max_segment 255
  @max_note 500
  # A card's picture, which the publisher sends with a version: small enough to ride beside
  # the files in one call, and one of the three kinds every browser draws. The plane checks
  # that the bytes start as that kind does, and neither decodes nor resizes them.
  @max_thumbnail_bytes 256 * 1024
  @thumbnail_types ~w(image/png image/jpeg image/webp)
  # A card's picture address names the person it was made for and lasts an hour or two: it
  # is made again at every list, the same within one hour, so a browser keeps the picture.
  @thumbnail_seconds 7200

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
  Publish `params` (`title`, `kind`, `visibility`, `teams`, `owner`, `files`, and `id` to
  republish) as `user`. `visibility` is `private` (the default) or `organisation`; `teams`
  the names of the teams that read it, each one the publisher is in or one granted the pod
  session's profile. `owner` is `me` (the default), `team` (the one team in `teams`) or
  `team:<name>`, a team the publisher is in. A republish keeps who reads it: `teams` there
  is refused, as on `put/3`.

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

    profile = opts[:session] && opts[:session].profile

    with :ok <- on(),
         :ok <- Sensitive.publishable(origin(opts)["session_id"]),
         {:ok, title} <- title(params["title"]),
         {:ok, kind} <- kind(params["kind"]),
         {:ok, visibility} <- new_visibility(params["visibility"]),
         :ok <- may_publish(user, visibility, admin?),
         {:ok, teams} <- team_names(params["teams"]),
         {:ok, teams} <- may_give(user, teams, profile, admin?),
         {:ok, owner_team} <- owner_for(user, params["owner"], teams, admin?),
         {:ok, note} <- note(params["note"]),
         {:ok, thumbnail} <- sent_thumbnail(params["thumbnail"]),
         {:ok, files} <- incoming(params, user),
         {:ok, _entry} <- entry(kind, files),
         {:ok, team_id} <- team_for(user, owner_team, opts[:session]) do
      write(user, nil, %{
        title: title,
        kind: kind,
        visibility: visibility,
        teams: teams,
        files: files,
        thumbnail: thumbnail,
        team_id: team_id,
        owner_team_id: owner_team && owner_team.id,
        origin: origin(opts),
        profile: profile,
        note: note,
        admin?: admin?
      })
      |> uploaded(params)
    end
  end

  @doc """
  A new version of artifact `params["id"]` at the same address: `files` (or `upload`, a
  handle from `begin_upload/2`), `note`, and `title`; with `base`, the version the files
  were edited on, whose files not sent are carried as they are, and which must still be the
  newest. An owner's, or an `edit` link's holder's. Whose it is and who reads it do not move
  here: a put naming `owner` is refused (`transfer/4` moves it), and so is one naming
  `teams` (`set_access/4`). `visibility`, an owner's alone, still moves it between
  `private` and `organisation` as a version of its own, for the clients that move it so.
  """
  @spec put(User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def put(%User{} = user, params, opts \\ []) when is_map(params) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         :ok <- owner_kept(params["owner"]),
         :ok <- readers_kept(params["teams"]),
         {:ok, artifact, role} <- editable(params["id"], user, admin?),
         {:ok, title} <- title(params["title"] || artifact.title),
         :ok <- same_kind(artifact, params["kind"]),
         {:ok, visibility} <- visibility(params["visibility"] || artifact.visibility),
         :ok <- may_move(artifact, visibility, role, user, admin?),
         :ok <- Sensitive.publishable(opts[:session] && opts[:session].id),
         :ok <- sensitive(artifact, moved(artifact, visibility, params), user, opts),
         {:ok, note} <- note(params["note"]),
         {:ok, thumbnail} <- sent_thumbnail(params["thumbnail"]),
         {:ok, base} <- base(artifact, params["base"]),
         {:ok, sent} <- incoming_over(base, params, user),
         files = carry(base, sent),
         {:ok, _entry} <- entry(artifact.kind, files),
         {:ok, team_id} <- team_of(artifact, user, opts[:session]) do
      write(user, artifact, %{
        title: title,
        kind: artifact.kind,
        visibility: visibility,
        files: files,
        thumbnail: thumbnail || same_page_thumbnail(base, sent),
        team_id: team_id,
        note: note,
        role: role,
        admin?: admin?
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
         {:ok, team_id} <- team_of(artifact, user, nil) do
      write(user, artifact, %{
        title: artifact.title,
        kind: artifact.kind,
        visibility: artifact.visibility,
        files: Enum.map(old.files, &carried(&1, old.n)),
        thumbnail: carried_thumbnail(old.thumbnail, old.n),
        team_id: team_id,
        note: "rolled back to v#{old.n}",
        rolled_back_to: old.n,
        role: role,
        admin?: admin?
      })
    else
      nil -> {:error, Error.new(:not_found, %{id: id, version: n})}
      {:error, _} = error -> error
    end
  end

  @doc """
  Pin version `n` as the one the artifact's address serves, or `nil` for the newest again.
  An owner's alone; audited as `artifact.pin`.
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
        artifact
        |> Ecto.Changeset.change(
          pinned: n,
          bytes: serves.bytes,
          thumbnail: serves.thumbnail,
          blocked: length(blocked(serves.files))
        )
        |> Repo.update!()

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
         {:ok, artifact} <- owned(id, user, admin?, "switches the public links of"),
         :ok <- if(enabled, do: sensitive(artifact, {"link", %{}}, user, opts), else: :ok) do
      artifact = artifact |> Ecto.Changeset.change(public_links: enabled) |> Repo.update!()
      {:ok, _event} = Audit.record(user.subject, "artifact.public", artifact.id, %{"enabled" => enabled})
      {:ok, answer(artifact, user, admin?)}
    end
  end

  @doc """
  Keep artifact `id` at the top of `user`'s own gallery (`on: true`), or let it go
  (`false`): anybody who may open it, for themselves alone. The person's view of their
  gallery, so nobody else sees it and it is not audited. `not_found` for one they may not
  open; a principal, which has no gallery, is `invalid_params`.
  """
  @spec keep(String.t(), term(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def keep(id, on, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- keepable(on, user),
         {:ok, artifact} <- visible(id, user, admin?) do
      :ok = Keeps.set(artifact.id, user, on)
      {:ok, answer(artifact, user, admin?)}
    end
  end

  defp keepable(on, _user) when not is_boolean(on),
    do: {:error, invalid("on is true, to keep it at the top of your gallery, or false, to let it go")}

  defp keepable(_on, %User{id: id}) when is_binary(id), do: :ok
  defp keepable(_on, _user), do: {:error, invalid("a principal has no gallery to keep an artifact at the top of")}

  defp answer(artifact, user, admin?),
    do: artifact |> Repo.preload([:owner, :owner_team, :team, :versions], force: true) |> to_json(user, admin?)

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

  # The single audiences an artifact had before its readers were a set: a client from then
  # is told where the teams went rather than having its move taken for something else.
  def visibility("team:" <> _name = other), do: {:error, invalid(set_now(other))}
  def visibility("profile:" <> _name = other), do: {:error, invalid(set_now(other))}

  def visibility(other),
    do: {:error, invalid("visibility is private or organisation, not #{inspect(other)}")}

  defp set_now(other),
    do:
      "visibility is private or organisation, not #{inspect(other)}: the teams that read an artifact " <>
        "are a set now, given with teams when it is published and changed with artifact.access.set"

  # The teams a publish or an access change names, by name, each once.
  defp team_names(nil), do: {:ok, []}

  defp team_names(names) when is_list(names) do
    if Enum.all?(names, &(is_binary(&1) and &1 =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/)),
      do: {:ok, Enum.uniq(names)},
      else: {:error, invalid("teams is a list of teams' names, not #{inspect(names)}")}
  end

  defp team_names(other), do: {:error, invalid("teams is a list of teams' names, not #{inspect(other)}")}

  # Who reads an artifact does not change with a version: `set_access/4` changes it.
  defp readers_kept(nil), do: :ok

  defp readers_kept(_teams),
    do:
      {:error,
       invalid("who reads an artifact does not change with a version; artifact.access.set changes its teams")}

  # Who a new artifact is for when its publisher says nothing: its owner alone.
  defp new_visibility(nil), do: visibility("private")
  defp new_visibility(visibility), do: visibility(visibility)

  # A republish that says nothing keeps who it is for.
  defp kept_visibility(nil), do: {:ok, nil}
  defp kept_visibility(visibility), do: visibility(visibility)

  # Whose a new artifact is: its publisher's, unless they say `team`, the one team that
  # reads it, or name a team they are in (a platform administrator any team there is). Who
  # reads it does not make it a team's: a team given it may be one its publisher is not in.
  defp owner_for(_user, nil, _teams, _admin?), do: {:ok, nil}
  defp owner_for(_user, "me", _teams, _admin?), do: {:ok, nil}
  defp owner_for(user, "team", [team], admin?), do: owner_for(user, "team:" <> team.name, [team], admin?)

  defp owner_for(_user, "team", _teams, _admin?),
    do:
      {:error,
       invalid(~s(owner is "team" only for an artifact one team reads; say owner: "team:<name>" or "me"))}

  defp owner_for(user, "team:" <> name, _teams, admin?) do
    with :ok <- team_word(name),
         :ok <- in_team(user, name, admin?, "give it an artifact") do
      team_named(name)
    end
  end

  defp owner_for(_user, other, _teams, _admin?),
    do: {:error, invalid("owner is me, team or team:<name>, not #{inspect(other)}")}

  defp team_word(name) do
    if name =~ ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/,
      do: :ok,
      else: {:error, invalid("#{inspect(name)} is not a team's name")}
  end

  defp team_named(name) do
    case Identity.get_team(name) do
      %Identity.Team{} = team -> {:ok, team}
      nil -> {:error, Error.new(:not_found, %{team: name, reason: "there is no team #{name}"})}
    end
  end

  # Whose an artifact is moves by `transfer/4` alone, which says who may and audits it as
  # a transfer; a version that also moved it would hide the move among publishes.
  defp owner_kept(nil), do: :ok

  defp owner_kept(_owner),
    do:
      {:error,
       invalid("whose an artifact is does not change with a version; artifact.transfer moves it")}

  defp may_publish(user, "organisation", admin?) do
    if Settings.get("artifacts_publish_organisation") == :platform_admins and not admin?,
      do:
        {:error,
         Error.new(:forbidden, %{
           reason:
             "only platform administrators publish to the whole organisation here; keep it private and give it to teams instead"
         })},
      else: covered(user)
  end

  # Its readers' alone: its owners and whoever they give it to.
  defp may_publish(user, "private", _admin?), do: covered(user)

  @doc """
  The names of the teams granted `profile`, sorted: those an artifact from a session on it
  may be given to by its owner, in them or not, since their people could already run that
  profile. None for no profile.
  """
  @spec profile_teams(String.t() | nil) :: [String.t()]
  def profile_teams(profile) when is_binary(profile),
    do: profile |> Identity.grants_for_profile() |> Enum.map(& &1.team.name) |> Enum.uniq() |> Enum.sort()

  def profile_teams(_none), do: []

  # The teams `names` are, each one `user` may give an artifact to: a team they are in, or
  # one granted the profile its session ran on (`profile`); a platform administrator any
  # team there is. A team that is not there is refused to anybody else as one they may not
  # give it to: whether it exists is not theirs to learn.
  defp may_give(_user, [], _profile, _admin?), do: {:ok, []}

  defp may_give(user, names, profile, admin?) do
    mine = teams_of(user)
    granted = profile_teams(profile)

    case Enum.reject(names, &(&1 in mine or &1 in granted)) do
      refused when refused == [] or admin? ->
        names |> Enum.map(&{&1, Identity.get_team(&1)}) |> found_teams()

      refused ->
        {:error, Error.new(:forbidden, %{teams: refused, reason: not_givable(refused, mine, granted, profile)})}
    end
  end

  defp found_teams(pairs) do
    case for({name, nil} <- pairs, do: name) do
      [] -> {:ok, Enum.map(pairs, &elem(&1, 1))}
      [name | _] -> {:error, Error.new(:not_found, %{team: name, reason: "there is no team #{name}"})}
    end
  end

  defp not_givable(refused, mine, granted, profile) do
    which = Words.and_list(Enum.map(refused, &"team #{&1}"))
    may = Enum.uniq(mine ++ granted)

    "you may not give it to #{which}: an artifact goes to teams you are in" <>
      if(profile, do: " and teams granted profile #{profile}, which its session ran on", else: "") <>
      if(may == [], do: ", and there are none", else: "; you may give it to #{Words.and_list(Enum.map(may, &"team #{&1}"))}")
  end

  # Whether `user` may do `what` with team `name`: in it, or a platform administrator for
  # one there is. A team that is not there is refused to anybody else as one they are not
  # in: whether it exists is not theirs to learn.
  defp in_team(user, name, admin?, what) do
    teams = teams_of(user)

    cond do
      name in teams ->
        :ok

      admin? and Identity.get_team(name) != nil ->
        :ok

      admin? ->
        {:error, Error.new(:not_found, %{team: name, reason: "there is no team #{name}"})}

      true ->
        {:error, Error.new(:forbidden, %{team: name, reason: not_in_team(name, teams, what)})}
    end
  end

  defp not_in_team(name, [], what),
    do: "you are not in team #{name}, so you cannot #{what}; you are in no team"

  defp not_in_team(name, teams, what),
    do:
      "you are not in team #{name}, so you cannot #{what}; you are in " <>
        Enum.map_join(teams, ", ", &"team:#{&1}")

  # The teams `user` is in, by name, read now: a team's members are its groups' members.
  defp teams_of(user), do: user |> Identity.teams_for() |> Enum.map(& &1.name)

  # The teams `user` administers: theirs to take a team's artifact down, and to take one
  # the team owns back. A principal administers nothing.
  defp administered_teams(%User{kind: "service"}), do: []
  defp administered_teams(%User{} = user), do: Identity.teams_administered_by(user)

  # Who `user` is to the teams, read once for a list: the names of those they are in and
  # administer, which the gallery's tabs go by, and the ids, which readers, takedowns and
  # ownership go by.
  defp audience_of(user) do
    teams = Identity.teams_for(user)
    administered = administered_teams(user)

    %{
      teams: Enum.map(teams, & &1.name),
      team_ids: Enum.map(teams, & &1.id),
      administered: Enum.map(administered, & &1.name),
      administered_ids: Enum.map(administered, & &1.id)
    }
  end

  # Whether `user` is an owner of `artifact`: its person, while no team owns it; else a
  # member or an administrator of the team that does, read now, so leaving the team is the
  # end of it at the next request.
  defp owns?(artifact, user, audience \\ nil)

  defp owns?(%Artifact{owner_team_id: nil, owner_id: owner}, %User{id: id}, _audience),
    do: is_binary(owner) and owner == id

  defp owns?(%Artifact{owner_team_id: team_id}, user, audience),
    do: team_id in ((audience && audience.team_ids ++ audience.administered_ids) || owning_ids(user))

  defp owning_ids(user), do: Enum.map(Identity.teams_for(user) ++ administered_teams(user), & &1.id)

  # Whether `user` could move whose `artifact` is: its person may give it to a team they
  # are in, a platform administrator may give any to any team or take any back, and an
  # administrator of the owning team may take it back. A member who does not administer
  # the team may not: the team's artifacts are not theirs to hand out.
  defp may_transfer?(_artifact, _user, true, _audience), do: true

  defp may_transfer?(%Artifact{owner_team_id: nil} = artifact, user, _admin?, audience),
    do: owns?(artifact, user, audience) and audience.team_ids != []

  defp may_transfer?(%Artifact{owner_team_id: team_id}, _user, _admin?, audience),
    do: team_id in audience.administered_ids

  # Whether `user` administers a team that reads `artifact`, from `administered` (the ids)
  # where a list read them once.
  defp administers?(artifact, user, administered \\ nil) do
    administered = administered || Enum.map(administered_teams(user), & &1.id)
    administered != [] and Enum.any?(Teams.ids(artifact), &(&1 in administered))
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

  # A file as a version keeps it, with what the artifacts host will block of what it loads,
  # read now from its bytes: a later version that carries the file carries that too.
  defp stored(path, body, type) do
    %{
      path: path,
      body: body,
      content_type: type,
      sha256: Digest.sha256(body),
      bytes: byte_size(body),
      blocked: Blocked.scan(path, type, body)
    }
  end

  # A Markdown artifact's documents are served as the page the host renders from them, so
  # what the host blocks there is read from the Markdown, whatever type the file was sent
  # with. A carried file has no body here and keeps what was found in it.
  defp rendered("markdown", %{body: body, path: path} = file) when is_binary(body) do
    if Markdown.document?(path), do: %{file | blocked: Blocked.markdown(path, body)}, else: file
  end

  defp rendered(_kind, file), do: file

  # One file that came by an upload handle, held to what a file sent inline is held to.
  defp checked_file(path, body, type) do
    with {:ok, path} <- path(%{"path" => path}),
         :ok <- within_file(path, body),
         {:ok, type} <- content_type(%{"content_type" => type}, path) do
      {:ok, stored(path, body, type)}
    end
  end

  # A path as an artifact keeps it, or why it is refused: relative, `/`-separated, no empty,
  # `.` or `..` segment nor one past 255 bytes, and not starting with a segment the host's addresses take (`v<n>`).
  @spec normalise_path(term()) :: {:ok, String.t()} | {:error, String.t()}
  defp normalise_path(path) when is_binary(path) do
    case Enum.find(path_rules(), fn {refused?, _why} -> refused?.(path) end) do
      nil -> {:ok, path}
      {_refused?, why} -> {:error, why.(path)}
    end
  end

  defp normalise_path(other), do: {:error, "a path is a string, not #{inspect(other)}"}

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

  defp within_version(total) when total > @max_version_bytes,
    do:
      {:error,
       Error.new(:payload_too_large, %{
         limit: @max_version_bytes,
         reason: "a version is at most #{@max_version_bytes} bytes"
       })}

  defp within_version(_total), do: :ok

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

  # Which team's quota the bytes count against: the team that owns it; else the pod
  # session's team; else the publisher's first team. Who reads it is not whose bytes they
  # are. Nobody in no team publishes.
  defp team_for(_user, %Identity.Team{id: id}, _session), do: {:ok, id}

  defp team_for(_user, _owner_team, %Session{team_id: team_id}) when is_binary(team_id),
    do: {:ok, team_id}

  defp team_for(user, _owner_team, _session) do
    case first_team(user) do
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
      stored_in: file["stored_in"] || n,
      blocked: file["blocked"] || []
    }
  end

  # The picture a version is sent with, for its card: `{content_type, bytes}` in base64, a
  # PNG, JPEG or WebP of at most 256 KiB whose bytes begin as that kind's do. None is none.
  defp sent_thumbnail(nil), do: {:ok, nil}

  defp sent_thumbnail(%{"content_type" => type, "bytes" => encoded}) when is_binary(type) and is_binary(encoded) do
    type = type |> String.trim() |> String.downcase()

    with :ok <- thumbnail_type(type),
         {:ok, body} <- thumbnail_body(encoded),
         :ok <- thumbnail_size(body),
         :ok <- thumbnail_kind(type, body) do
      {:ok, %{body: body, content_type: type, sha256: Digest.sha256(body), bytes: byte_size(body)}}
    end
  end

  defp sent_thumbnail(_other),
    do:
      {:error,
       invalid(
         "thumbnail is {content_type, bytes}: a PNG, JPEG or WebP picture of the page, " <>
           "at most #{@max_thumbnail_bytes} bytes, in base64"
       )}

  defp thumbnail_type(type) when type in @thumbnail_types, do: :ok

  defp thumbnail_type(type),
    do: {:error, invalid("a thumbnail is image/png, image/jpeg or image/webp, not #{inspect(type)}")}

  defp thumbnail_body(encoded) do
    case Base.decode64(encoded, ignore: :whitespace) do
      {:ok, ""} -> {:error, invalid("the thumbnail is empty")}
      {:ok, body} -> {:ok, body}
      :error -> {:error, invalid("the thumbnail's bytes are not base64")}
    end
  end

  defp thumbnail_size(body) when byte_size(body) > @max_thumbnail_bytes,
    do:
      {:error,
       invalid(
         "the thumbnail is #{byte_size(body)} bytes, past the #{@max_thumbnail_bytes} a thumbnail may be; " <>
           "send a smaller picture"
       )}

  defp thumbnail_size(_body), do: :ok

  # Only the first bytes, which say what a file is: enough to refuse a page or a script
  # sent as a picture, without reading the picture itself.
  defp thumbnail_kind("image/png", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: :ok
  defp thumbnail_kind("image/jpeg", <<0xFF, 0xD8, 0xFF, _::binary>>), do: :ok
  defp thumbnail_kind("image/webp", <<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: :ok

  defp thumbnail_kind(type, _body),
    do: {:error, invalid("the thumbnail's bytes are not a #{picture_kind(type)} picture, as its content_type says")}

  defp picture_kind("image/png"), do: "PNG"
  defp picture_kind("image/jpeg"), do: "JPEG"
  defp picture_kind("image/webp"), do: "WebP"

  # A version that sends no file of its own is the page its base was, so it keeps the base's
  # picture; one that sends any file is another page, and has only the picture sent with it.
  defp same_page_thumbnail(%Version{thumbnail: thumbnail, n: n}, []), do: carried_thumbnail(thumbnail, n)
  defp same_page_thumbnail(_base, _sent), do: nil

  # Version `n`'s picture in a later version: its object stays where it is.
  defp carried_thumbnail(%{} = thumbnail, n) do
    %{
      content_type: thumbnail["content_type"],
      sha256: thumbnail["sha256"],
      bytes: thumbnail["bytes"],
      stored_in: thumbnail["stored_in"] || n
    }
  end

  defp carried_thumbnail(_none, _n), do: nil

  # The files a call carries: inline, or in the object store under an upload handle.
  defp incoming(%{"upload" => handle}, user) when is_binary(handle),
    do: Uploads.take(handle, user, store(), &checked_file/3)

  defp incoming(params, _user), do: files(params["files"])

  # Over a base, a put may send no files at all: every one of the base's is carried, which
  # is how its owner moves who may open it, or retitles it, without sending it again.
  defp incoming_over(%Version{}, params, _user) when not is_map_key(params, "files") and not is_map_key(params, "upload"),
    do: {:ok, []}

  defp incoming_over(_base, params, user), do: incoming(params, user)

  # The team a new version counts against: the artifact's, while there is one; else as a
  # new one's would be.
  defp team_of(%Artifact{team_id: team_id}, _user, _session) when is_binary(team_id),
    do: {:ok, team_id}

  defp team_of(_artifact, user, session), do: team_for(user, nil, session)

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

  # An artifact a sensitive session published is shared wider only as its profile's
  # `sensitive.sharing` says (`Troupe.Plane.Sessions.Sensitive`): moved to a wider
  # audience, shared with a person, or given a link. A team administrator's yes to a held
  # share comes back with `sensitive: :approved`.
  defp sensitive(_artifact, nil, _user, _opts), do: :ok

  defp sensitive(artifact, {kind, params}, user, opts) do
    if Keyword.get(opts, :sensitive) == :approved,
      do: :ok,
      else: Sensitive.check_artifact(artifact, kind, params, user)
  end

  # A visibility other than the one it has and other than the owner's alone is wider. What
  # waits is the move alone, onto the version it was asked on (`base`): a new version's
  # files sent with it do not wait, and are refused with the move.
  defp moved(%{visibility: visibility}, visibility, _params), do: nil
  defp moved(_artifact, "private", _params), do: nil

  defp moved(_artifact, visibility, params) do
    files? = Map.has_key?(params, "files") or Map.has_key?(params, "upload")
    {"artifact", %{"visibility" => visibility, "base" => params["base"], "with_files" => files?}}
  end

  defp string_or_nil(value) when is_binary(value) and byte_size(value) in 1..200, do: value
  defp string_or_nil(_value), do: nil

  # One version written: its new files into the object store, its row, the artifact's, and
  # the audit. A version that is not written leaves no object behind: what was put before the
  # refusal or the failure is taken back.
  defp write(user, existing, attrs) do
    attrs = %{attrs | files: Enum.map(attrs.files, &rendered(attrs.kind, &1))}
    bytes = attrs.files |> Enum.map(& &1.bytes) |> Enum.sum()
    thumbnail = attrs[:thumbnail]
    new_bytes = new_bytes(attrs.files, thumbnail)
    moved = moved_bytes(existing, attrs.team_id)
    hash = version_hash(attrs.files)
    blocked = blocked(attrs.files)
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      artifact = lock(existing) || new_artifact(user, attrs, now)
      n = (existing && artifact.version + 1) || 1
      # A new one's readers, given with it; a version's are the artifact's, kept as they are.
      :ok = Teams.add(artifact.id, given_teams(existing, attrs), user.subject)

      with :ok <- republishable(existing, attrs),
           :ok <- within_version(bytes),
           :ok <- within_quota(attrs.team_id, new_bytes + moved, existing),
           :ok <- put_objects(artifact.id, n, attrs.files),
           :ok <- put_thumbnail(artifact.id, n, thumbnail, attrs.files) do
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
            rolled_back_to: attrs[:rolled_back_to],
            thumbnail: thumbnail_json(thumbnail)
          })

          artifact =
            artifact
            |> Ecto.Changeset.change(
              Map.merge(in_force(artifact, bytes, thumbnail, blocked), %{
                title: attrs.title,
                visibility: attrs.visibility,
                team_id: attrs.team_id,
                version: n,
                total_bytes: artifact.total_bytes + new_bytes,
                updated_at: now
              })
            )
            |> Repo.update!()

          artifact = Repo.preload(artifact, :owner_team)
          {action, detail} = audit_detail(artifact, existing, n, hash, bytes, attrs)
          {:ok, _event} = Audit.record(user.subject, action, artifact.id, detail)
          artifact
        rescue
          exception ->
            take_back(artifact.id, n, attrs.files)
            take_back_thumbnail(artifact.id, n, thumbnail)
            reraise exception, __STACKTRACE__
        end
      else
        {:error, error} -> Repo.rollback(error)
      end
    end)
    |> case do
      # What the host will block in the version just written, for its publisher to correct,
      # whichever version the address serves.
      {:ok, artifact} -> {:ok, artifact |> answer(user, attrs[:admin?] || false) |> Map.put("blocked", blocked)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  # What a version puts in the store: the files it brings (not those it carries) and the
  # picture sent with it, which counts as a file does.
  defp new_bytes(files, thumbnail) do
    sent = files |> Enum.filter(&Map.has_key?(&1, :body)) |> Enum.map(& &1.bytes) |> Enum.sum()

    case thumbnail do
      %{body: _, bytes: picture} -> sent + picture
      _carried_or_none -> sent
    end
  end

  # The size, picture and blocked count the artifact's address serves: the new version's,
  # unless the owner pinned another, which keeps serving.
  defp in_force(%Artifact{pinned: pinned} = artifact, _bytes, _thumbnail, _blocked) when is_integer(pinned),
    do: %{bytes: artifact.bytes, thumbnail: artifact.thumbnail, blocked: artifact.blocked}

  defp in_force(_artifact, bytes, thumbnail, blocked),
    do: %{bytes: bytes, thumbnail: thumbnail_json(thumbnail), blocked: length(blocked)}

  defp given_teams(nil, attrs), do: attrs[:teams] || []
  defp given_teams(_existing, _attrs), do: []

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
      owner_team_id: attrs[:owner_team_id],
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

  # The picture sent with a version, into the object store beside its files; refused, it
  # takes the files back too, so the version leaves nothing. A carried one is stored already.
  defp put_thumbnail(id, n, %{body: body, content_type: type}, files) do
    case ObjectStore.put(store(), thumbnail_key(id, n), body, content_type: type) do
      {:ok, _put} ->
        :ok

      {:error, reason} ->
        take_back(id, n, files)

        {:error,
         Error.new(:unavailable, %{reason: "the object store refused the thumbnail: #{inspect(reason)}"})}
    end
  end

  defp put_thumbnail(_id, _n, _carried_or_none, _files), do: :ok

  defp take_back_thumbnail(id, n, %{body: _}), do: ObjectStore.delete(store(), thumbnail_key(id, n))
  defp take_back_thumbnail(_id, _n, _carried_or_none), do: :ok

  defp thumbnail_json(nil), do: nil

  defp thumbnail_json(thumbnail) do
    %{
      "content_type" => thumbnail.content_type,
      "sha256" => thumbnail.sha256,
      "bytes" => thumbnail.bytes
    }
    |> then(&if(thumbnail[:stored_in], do: Map.put(&1, "stored_in", thumbnail.stored_in), else: &1))
  end

  # Beside the version's files, never among them: a path is `artifacts/<id>/<n>/…`, and no
  # version is called `thumbnails`.
  defp thumbnail_key(id, n), do: "artifacts/#{id}/thumbnails/#{n}"

  defp audit_detail(artifact, existing, n, hash, bytes, attrs) do
    detail =
      %{
        "version" => n,
        "title" => artifact.title,
        "kind" => artifact.kind,
        "visibility" => artifact.visibility,
        # The team it belongs to, where one does.
        "owner_team" => team_name(artifact.owner_team),
        # The teams a new one was given to; a version's readers are not its to change.
        "teams" => if(existing == nil and attrs[:teams] not in [nil, []], do: Enum.map(attrs.teams, & &1.name)),
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
    |> then(&if(file[:blocked] in [nil, []], do: &1, else: Map.put(&1, "blocked", file.blocked)))
  end

  # What the artifacts host blocks in a version, file by file, from what each file kept.
  defp blocked(files), do: Enum.flat_map(files, &(&1[:blocked] || &1["blocked"] || []))

  defp version_hash(files) do
    lines = Enum.map_join(files, "", &"#{&1.path}\0#{&1.sha256}\n")
    "sha256:" <> Digest.sha256(lines)
  end

  defp new_id do
    "art-" <> (10 |> :crypto.strong_rand_bytes() |> Base.encode32(case: :lower, padding: false))
  end

  defp key(id, n, path), do: "artifacts/#{id}/#{n}/#{path}"

  # -- reading --------------------------------------------------------------------

  @doc """
  What `user` may see, newest published first, narrowed by `mine`, `shared` (the ones a link
  or a grant by name gave them), `teams` (those a team of theirs reads), `team` (those one
  team reads) or `visibility`. Each row says its `scope`, the gallery tab it is under, and
  who reads it (`teams`, `organisation`). `teams` beside them is the caller's own;
  `profiles` is always empty, kept for the clients that still read it.
  """
  @spec list(User.t(), map(), keyword()) :: {:ok, map()}
  def list(%User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    audience = audience_of(user)

    # The ones the caller keeps at the top are never left out for being old: taken first
    # into the 500, then put back where they fall, newest first.
    kept = Keeps.ids(user)

    artifacts =
      if enabled?() do
        user
        |> visible_query(audience, admin?)
        |> narrow(params, user, audience, admin?)
        |> order_by([a], desc: a.id in ^kept, desc: a.updated_at)
        |> limit(500)
        |> preload([:owner, :owner_team, :team, team_grants: :team])
        |> Repo.all()
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
        |> with_roles(user, admin?, audience)
        |> Enum.map(fn {artifact, meta} -> to_json(artifact, user, admin?, meta) end)
      else
        []
      end

    {:ok,
     %{
       "enabled" => enabled?(),
       "profiles" => [],
       "teams" => audience.teams,
       "publish_organisation" =>
         to_string(Settings.get("artifacts_publish_organisation") || :everyone),
       "public_links" => Shares.public_links?(),
       "gallery_url" => console_url() && console_url() <> "#/artifacts",
       "artifacts" => artifacts
     }}
  end

  # A platform administrator sees every one but a person's own that only they and whoever
  # they named read; anybody else their own (their person's, or their teams'), those a link
  # or a grant gave them, and those read by somebody they are: the organisation, or a team
  # they are in or administer.
  defp visible_query(user, audience, true) do
    from(a in Artifact, where: a.visibility != "private")
    |> or_where([a], a.id in subquery(Teams.any()))
    |> or_where([a], a.id in subquery(owned_query(user, audience)))
    |> or_where([a], a.id in subquery(Shares.shared_with(user)))
  end

  defp visible_query(user, audience, false) do
    from(a in Artifact, where: a.visibility == "organisation")
    |> or_where([a], a.id in subquery(Teams.reading(audience.team_ids ++ audience.administered_ids)))
    |> or_where([a], a.id in subquery(owned_query(user, audience)))
    |> or_where([a], a.id in subquery(Shares.shared_with(user)))
  end

  # The ids of the artifacts `user` owns, as `owns?/3` has it, as a query.
  defp owned_query(%User{id: id}, audience) do
    owning = audience.team_ids ++ audience.administered_ids
    query = from(a in Artifact, where: a.owner_team_id in ^owning, select: a.id)

    if is_binary(id),
      do: or_where(query, [a], a.owner_id == ^id and is_nil(a.owner_team_id)),
      else: query
  end

  # Those teams read: any team's for a platform administrator, else those a team the caller
  # is in or administers reads, and not one a link alone reached, which is shared.
  defp narrow(query, %{"teams" => true}, _user, _audience, true),
    do: where(query, [a], a.id in subquery(Teams.any()))

  defp narrow(query, %{"teams" => true}, _user, audience, _admin?),
    do: where(query, [a], a.id in subquery(Teams.reading(audience.team_ids ++ audience.administered_ids)))

  # Those one team reads, by its name.
  defp narrow(query, %{"team" => name}, _user, _audience, _admin?) when is_binary(name),
    do: where(query, [a], a.id in subquery(Teams.read_by([name])))

  # Their own: their person's, and their teams'.
  defp narrow(query, %{"mine" => true}, user, audience, _admin?),
    do: where(query, [a], a.id in subquery(owned_query(user, audience)))

  # What a link or a grant alone gave them: not one they own, however it reached them.
  defp narrow(query, %{"shared" => true}, %User{id: id} = user, audience, _admin?) when is_binary(id) do
    shared = Shares.shared_with(user)
    owned = owned_query(user, audience)
    where(query, [a], a.id in subquery(shared) and a.id not in subquery(owned))
  end

  defp narrow(query, %{"shared" => true}, _user, _audience, _admin?), do: where(query, [a], false)

  defp narrow(query, %{"visibility" => visibility}, _user, _audience, _admin?) when is_binary(visibility),
    do: where(query, [a], a.visibility == ^visibility)

  defp narrow(query, _params, _user, _audience, _admin?), do: query

  @doc """
  One artifact with its versions, if `user` may see it; for an owner, who reads it
  (`access`, as `access/3` answers it), who holds a link to it, who it is shared with by
  name, and whether a public link may be made.
  """
  @spec get(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- visible(id, user, admin?) do
      artifact = artifact |> Repo.preload([:owner, :owner_team, :team, :versions, team_grants: :team])
      # How long it and its old versions are kept, which its page says beside the dates.
      json = artifact |> to_json(user, admin?) |> Map.put("retention", retention())

      if json["role"] == "owner",
        do:
          {:ok,
           Map.merge(json, %{
             "access" => access_json(artifact),
             "shares" => Shares.list(artifact),
             "people" => People.list(artifact),
             "public_links_allowed" => Shares.public_links?()
           })},
        else: {:ok, json}
    end
  end

  @doc """
  The artifact `id` if `user` may see it, read now. `not_found` for one they may not, as for
  one that is not there, and for every one while artifacts are off. A platform administrator
  sees every one but a person's own that no team or the organisation reads, and a team's
  administrator those their teams read.
  """
  @spec visible(term(), User.t(), boolean()) :: {:ok, Artifact.t()} | {:error, Error.t()}
  def visible(id, %User{} = user, admin?) when is_binary(id) do
    with true <- enabled?(),
         %Artifact{} = artifact <- Repo.get(Artifact, id),
         true <-
           (admin? and (artifact.visibility != "private" or Teams.ids(artifact) != [])) or
             sees?(artifact, user) or administers?(artifact, user) do
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
  What `user` is to `artifact` now: `owner` (its person, or in the team that owns it);
  `edit`, `comment` or `view` through a link of an owner's they were signed in through, or
  a grant by name, while it lasts; `view` through a team of theirs that reads it, or the
  organisation; or `nil`.
  """
  @spec role(Artifact.t(), User.t()) :: String.t() | nil
  def role(%Artifact{} = artifact, %User{} = user),
    do: if(owns?(artifact, user), do: "owner", else: linked_role(artifact, user))

  defp linked_role(artifact, user) do
    case Shares.role(artifact, user) do
      linked when linked in ["edit", "comment"] -> linked
      linked -> if(linked == "view" or for?(artifact, user), do: "view")
    end
  end

  # Whether `artifact` is read by somebody `user` is, from `audience` where a list read what
  # they are in once: the organisation, or a team of theirs.
  defp for?(artifact, user, audience \\ nil), do: reached(artifact, user, audience) != nil

  # How it reaches them: through a team of theirs that reads it (`{:team, name}`, the first
  # by name), else the organisation; `nil` where neither does.
  defp reached(artifact, user, audience) do
    team_ids = (audience && audience.team_ids) || Enum.map(Identity.teams_for(user), & &1.id)

    cond do
      team = Enum.find(teams_named(artifact), &(&1.id in team_ids)) -> {:team, team.name}
      artifact.visibility == "organisation" and covered(user) == :ok -> :organisation
      true -> nil
    end
  end

  # The teams that read it, sorted by name, from its preloaded grants where it has them.
  defp teams_named(%Artifact{team_grants: grants}) when is_list(grants) do
    grants |> Repo.preload(:team) |> Enum.map(& &1.team) |> Enum.sort_by(& &1.name)
  end

  defp teams_named(artifact),
    do: artifact |> Repo.preload(team_grants: :team) |> teams_named()

  # A list's roles in one query for its links, rather than one per artifact.
  defp with_roles(artifacts, user, admin?, audience) do
    ids = Enum.map(artifacts, & &1.id)
    linked = Shares.roles(ids, user)
    public = Shares.public_ids(ids)
    comments = Comments.counts(ids)
    kept = Keeps.among(ids, user)

    Enum.map(artifacts, fn artifact ->
      reached = reached(artifact, user, audience)
      link = linked[artifact.id]

      role =
        cond do
          owns?(artifact, user, audience) -> "owner"
          link in ["edit", "comment"] -> link
          link == "view" or reached != nil -> "view"
          true -> nil
        end

      {artifact,
       %{
         role: role,
         comments: Map.get(comments, artifact.id, {0, nil}),
         kept: MapSet.member?(kept, artifact.id),
         public: MapSet.member?(public, artifact.id),
         scope: scope(artifact, role, reached, link),
         administers: administers?(artifact, user, audience.administered_ids),
         may_transfer: may_transfer?(artifact, user, admin?, audience)
       }}
    end)
  end

  # One artifact's, read as a list of one would be, so the two agree.
  defp meta_of(artifact, user, admin?) do
    [{_artifact, meta}] = with_roles([artifact], user, admin?, audience_of(user))
    meta
  end

  # The gallery tab a row is under: the caller's own (`private` for one nobody else reads
  # by team or as the organisation); the team of theirs that reads it, or `organisation`;
  # `shared` where only a link or a grant does; else who reads it, as an administrator sees
  # it: the organisation, the first team, or `private`.
  defp scope(artifact, "owner", _reached, _link) do
    if artifact.visibility == "private" and Teams.ids(artifact) == [], do: "private", else: "mine"
  end

  defp scope(_artifact, _role, {:team, name}, _link), do: "team:" <> name
  defp scope(_artifact, _role, :organisation, _link), do: "organisation"
  defp scope(_artifact, _role, nil, link) when link in ["view", "comment", "edit"], do: "shared"

  defp scope(artifact, _role, nil, _link) do
    case {artifact.visibility, teams_named(artifact)} do
      {"organisation", _teams} -> "organisation"
      {_private, [team | _]} -> "team:" <> team.name
      {visibility, []} -> visibility
    end
  end

  # -- who reads it ------------------------------------------------------------------

  @doc """
  Who reads artifact `id`, for its owner or a platform administrator: its owner (`owner`, the
  person, and `owner_team`), the teams that read it (`teams`, each `{name, granted_by, at}`),
  the people it is shared with by name at their roles (`people`), whether every signed-in
  person reads it (`organisation`), its links (`links`), and the teams the owner may add
  (`may_add`): theirs, and those granted the profile its session ran on.
  """
  @spec access(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def access(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact} <- reader_keeper(id, user, admin?) do
      artifact = Repo.preload(artifact, [:owner, :owner_team])

      {:ok,
       artifact
       |> access_json()
       |> Map.merge(%{
         "id" => artifact.id,
         "may_add" => Enum.uniq(teams_of(user) ++ profile_teams(artifact.profile)) |> Enum.sort()
       })}
    end
  end

  # Its owner's to read, and a platform administrator's, whose takedowns are read from it.
  defp reader_keeper(id, user, true), do: findable(id, user, true)

  defp reader_keeper(id, user, false), do: owned(id, user, false, "reads who reads")

  # Who reads it, in the shape `access/3` answers and `get/3` carries for an owner.
  defp access_json(artifact) do
    artifact = Repo.preload(artifact, [:owner, :owner_team])

    %{
      "owner" => person(artifact.owner),
      "owner_team" => team_name(artifact.owner_team),
      "teams" => Teams.list(artifact),
      "people" => Enum.map(People.list(artifact), &Map.take(&1, ["subject", "display_name", "role"])),
      "organisation" => artifact.visibility == "organisation",
      "links" => Shares.list(artifact),
      "words" => readers_words(artifact)
    }
  end

  @doc """
  Who reads `artifact` beside its owners, in words, for the gate that asks about a new
  version of it: "the Clinics and Billing teams and 3 people; a view link", "the whole
  organisation", or "nobody else" where no team, person, organisation or live link does.
  """
  @spec readers_words(Artifact.t()) :: String.t()
  def readers_words(%Artifact{} = artifact) do
    readers =
      Enum.reject(
        [
          organisation_words(artifact.visibility),
          teams_words(Teams.names(artifact)),
          people_words(length(People.list(artifact)))
        ],
        &is_nil/1
      )

    linked =
      artifact
      |> Shares.list()
      |> Enum.filter(&(&1["state"] == "live"))
      |> Enum.frequencies_by(& &1["role"])
      |> Enum.sort()
      |> Enum.map(fn {role, n} -> Words.count(n, "#{role} link") |> String.replace(~r/\A1 /, "a ") end)

    case {readers, linked} do
      {[], []} -> "nobody else"
      {readers, []} -> Words.and_list(readers)
      {[], linked} -> Words.and_list(linked)
      {readers, linked} -> Words.and_list(readers) <> "; " <> Words.and_list(linked)
    end
  end

  defp organisation_words("organisation"), do: "the whole organisation"
  defp organisation_words(_private), do: nil

  defp teams_words([]), do: nil
  defp teams_words([one]), do: "the #{one} team"
  defp teams_words(many), do: "the #{Words.and_list(many)} teams"

  defp people_words(0), do: nil
  defp people_words(n), do: Words.count(n, "person", "people")

  @doc """
  Change who reads artifact `id`, its owner's alone: `teams`, the names of every team that
  should read it; `people`, every person it should be shared with by name, each
  `{subject, role}`; `organisation`, whether every signed-in person reads it. Each is the
  whole of that part and is applied as the difference from what is there: each team or
  person added or taken off is one `artifact.share` or `artifact.unshare` row in the audit
  (`team` or `person` in its detail), and the organisation switch one `artifact.visibility`
  row with what it moved from. A part not named is left as it is; nothing here makes a
  version. A team added is one the owner is in or one granted the profile the artifact's
  session ran on; any other is refused, and nothing is changed. Answers `access/3`'s.
  """
  @spec set_access(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def set_access(id, %User{} = user, params, opts \\ []) when is_map(params) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, admin?, "changes who reads"),
         {:ok, team_change} <- team_change(artifact, user, params["teams"], admin?),
         {:ok, people_change} <- people_change(artifact, params["people"]),
         {:ok, visibility} <- organisation_change(artifact, user, params["organisation"], admin?),
         :ok <- widening(artifact, user, {team_change, people_change, visibility}, params, opts),
         {:ok, :ok} <- Repo.transaction(fn -> changed(artifact, user, team_change, people_change, visibility) end) do
      People.told(artifact, user, Enum.map(elem(people_change, 0), &elem(&1, 0)))
      access(artifact.id, user, opts)
    end
  end

  # Every part of a change at once, or none of it where a person is refused.
  defp changed(artifact, user, team_change, people_change, visibility) do
    :ok = apply_teams(artifact, user, team_change)
    :ok = apply_visibility(artifact, user, visibility)

    case apply_people(artifact, user, people_change) do
      :ok -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  # The teams to add and to take off, by the names `names` says should read it.
  defp team_change(_artifact, _user, nil, _admin?), do: {:ok, {[], []}}

  defp team_change(artifact, user, names, admin?) do
    with {:ok, names} <- team_names(names) do
      there = teams_named(artifact)
      added = names -- Enum.map(there, & &1.name)

      with {:ok, added} <- may_give(user, added, artifact.profile, admin?),
           do: {:ok, {added, Enum.reject(there, &(&1.name in names))}}
    end
  end

  defp apply_teams(artifact, user, {added, removed}) do
    :ok = Teams.add(artifact.id, added, user.subject)
    :ok = Teams.remove(artifact.id, removed)

    Enum.each(added, &audit_readers(user, "artifact.share", artifact, %{"team" => &1.name}))
    Enum.each(removed, &audit_readers(user, "artifact.unshare", artifact, %{"team" => &1.name}))
  end

  # The people to grant (new, or at another role) and to take off, by `people`.
  defp people_change(_artifact, nil), do: {:ok, {[], []}}

  defp people_change(artifact, people) when is_list(people) do
    if Enum.all?(people, &match?(%{"subject" => subject} when is_binary(subject), &1)) do
      there = Map.new(People.list(artifact), &{&1["subject"], &1["role"]})
      wanted = Map.new(people, &{&1["subject"], &1["role"]})
      granted = Enum.reject(wanted, fn {subject, role} -> there[subject] == role end)
      {:ok, {granted, Map.keys(there) -- Map.keys(wanted)}}
    else
      {:error, invalid("people is a list of {subject, role}, not #{inspect(people)}")}
    end
  end

  defp people_change(_artifact, other),
    do: {:error, invalid("people is a list of {subject, role}, not #{inspect(other)}")}

  # Each grant as `artifact.share {person}` makes it, stopping at the first refused, and each
  # one taken off as its revoke.
  defp apply_people(artifact, user, {granted, removed}) do
    Enum.each(removed, fn subject ->
      if People.revoke(artifact, subject) > 0,
        do: audit_readers(user, "artifact.unshare", artifact, %{"person" => subject})
    end)

    Enum.reduce_while(granted, :ok, fn {subject, role}, :ok ->
      case People.grant(artifact, user, subject, role) do
        {:ok, _granted} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The organisation switch, as `visibility` keeps it: unsaid or unchanged, nothing to do.
  defp organisation_change(_artifact, _user, nil, _admin?), do: {:ok, nil}

  defp organisation_change(artifact, user, on, admin?) when is_boolean(on) do
    visibility = if on, do: "organisation", else: "private"

    cond do
      visibility == artifact.visibility -> {:ok, nil}
      on -> with :ok <- may_publish(user, visibility, admin?), do: {:ok, visibility}
      true -> {:ok, visibility}
    end
  end

  defp organisation_change(_artifact, _user, other, _admin?),
    do: {:error, invalid("organisation is true or false, not #{inspect(other)}")}

  defp apply_visibility(_artifact, _user, nil), do: :ok

  defp apply_visibility(artifact, user, visibility) do
    artifact |> Ecto.Changeset.change(visibility: visibility) |> Repo.update!()

    audit_readers(user, "artifact.visibility", artifact, %{
      "visibility" => visibility,
      "visibility_from" => artifact.visibility,
      "title" => artifact.title
    })
  end

  defp audit_readers(user, action, artifact, detail) do
    {:ok, _event} = Audit.record(user.subject, action, artifact.id, detail)
    :ok
  end

  # A change that adds readers (a team, a person or a role, the organisation) to an
  # artifact a sensitive session published goes through that session's sharing rule, as a
  # share with a person does; held, it waits whole for a team administrator's yes, and the
  # answer says so. A change that only takes readers off is the owner's alone.
  defp widening(artifact, user, {{added, _removed}, {granted, _taken}, visibility}, params, opts) do
    if added != [] or granted != [] or visibility == "organisation" do
      access = Map.take(params, ["teams", "people", "organisation"])
      sensitive(artifact, {"artifact", %{"access" => access}}, user, opts)
    else
      :ok
    end
  end

  @doc """
  The profile artifact `id` came from, for the people search of its owner's sharing menu:
  `{:ok, nil}` for one no pod session published; `not_found` for one `user` does not own.
  """
  @spec profile_of(String.t(), User.t(), keyword()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def profile_of(id, %User{} = user, opts \\ []) do
    with {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "shares") do
      {:ok, artifact.profile}
    end
  end

  @doc "Whether `user` owns an artifact published from a session on `profile`."
  @spec owns_from?(User.t(), String.t()) :: boolean()
  def owns_from?(%User{} = user, profile) when is_binary(profile) do
    owned = owned_query(user, audience_of(user))
    Repo.exists?(from(a in Artifact, where: a.profile == ^profile and a.id in subquery(owned)))
  end

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
         {:ok, entry} <- file_path(artifact, found, path),
         {:ok, file, body} <- file_of(artifact, found, entry) do
      # Its entry page is somebody opening it, which keeps it under the unopened period.
      if is_nil(path), do: Retention.touch(artifact)
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
  Delete an artifact, every version and every byte: an owner's (its person, or anybody in
  the team that owns it), or a takedown by a platform administrator (any, a private one
  too) or by the administrator of the team it is for. Audited as `artifact.delete` with
  which it was.
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

  defp deleter(artifact, user, admin?) do
    cond do
      owns?(artifact, user) ->
        {:ok, "owner"}

      admin? or administers?(artifact, user) ->
        {:ok, "takedown"}

      true ->
        {:error,
         Error.new(:forbidden, %{
           id: artifact.id,
           reason:
             "only its owner, a platform administrator, or an administrator of a team that reads it deletes an artifact"
         })}
    end
  end

  # -- whose it is ------------------------------------------------------------------

  @doc """
  Give artifact `id` to a team (`to: "team:<name>"`) or take it back (`to: "me"`), which
  makes the caller its person. Its person gives it to a team they are in; a platform
  administrator gives any artifact to any team there is; an administrator of the team that
  owns it, or a platform administrator, takes it back. A member who does not administer
  the team may not: the team's artifacts are not theirs to hand out. Audited as
  `artifact.transfer` with `from` (`person` or `team:<name>`), `to` and the title.
  """
  @spec transfer(String.t(), term(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def transfer(id, to, user, opts \\ [])

  def transfer(id, to, %User{} = user, opts) when is_binary(id) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, destination} <- destination(to),
         {:ok, artifact} <- findable(id, user, admin?),
         artifact = Repo.preload(artifact, :owner_team),
         {:ok, changes} <- transferable(artifact, destination, user, admin?) do
      moved = artifact |> Ecto.Changeset.change(changes) |> Repo.update!()

      {:ok, _event} =
        Audit.record(user.subject, "artifact.transfer", artifact.id, %{
          "from" => if(artifact.owner_team, do: "team:#{artifact.owner_team.name}", else: "person"),
          "to" => to,
          "title" => artifact.title
        })

      {:ok, answer(moved, user, admin?)}
    end
  end

  def transfer(other, _to, _user, _opts), do: {:error, invalid("id is an artifact's id, not #{inspect(other)}")}

  defp destination("me"), do: {:ok, :me}

  defp destination("team:" <> name) do
    with :ok <- team_word(name), do: {:ok, {:team, name}}
  end

  defp destination(other), do: {:error, invalid("to is me or team:<name>, not #{inspect(other)}")}

  # To a team: its person's, to one they are in; a platform administrator's, to any there
  # is, from a person or from another team. Back: from the team that owns it, by one of
  # its administrators or a platform administrator.
  defp transferable(%Artifact{owner_team_id: nil} = artifact, {:team, name}, user, admin?) do
    if admin? or owns?(artifact, user) do
      with :ok <- in_team(user, name, admin?, "give it an artifact"),
           {:ok, team} <- team_named(name) do
        {:ok, %{owner_team_id: team.id}}
      end
    else
      {:error, Error.new(:forbidden, %{id: artifact.id, reason: "only its owner gives an artifact to a team"})}
    end
  end

  defp transferable(%Artifact{owner_team: owning} = artifact, {:team, name}, _user, admin?) do
    if admin? do
      with {:ok, team} <- team_named(name), do: {:ok, %{owner_team_id: team.id}}
    else
      {:error,
       Error.new(:forbidden, %{
         id: artifact.id,
         reason:
           "this artifact is team #{owning.name}'s; only a platform administrator gives a team's artifact to another team, " <>
             "and an administrator of team #{owning.name} takes it back (to: \"me\")"
       })}
    end
  end

  defp transferable(%Artifact{owner_team_id: nil} = artifact, :me, _user, _admin?),
    do:
      {:error,
       Error.new(:invalid_params, %{
         id: artifact.id,
         reason: "this artifact is not a team's, so there is nothing to take back"
       })}

  defp transferable(%Artifact{owner_team: owning} = artifact, :me, user, admin?) do
    if admin? or owning.id in Enum.map(administered_teams(user), & &1.id),
      do: {:ok, %{owner_team_id: nil, owner_id: user.id}},
      else:
        {:error,
         Error.new(:forbidden, %{
           id: artifact.id,
           reason:
             "only an administrator of team #{owning.name}, or a platform administrator, takes an artifact back from the team"
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
        :all ->
          from(a in Artifact)

        names ->
          # Those the teams read, and those the teams own, whoever reads them.
          owned = from(t in Identity.Team, where: t.name in ^names, select: t.id)

          from(a in Artifact,
            where: a.id in subquery(Teams.read_by(names)) or a.owner_team_id in subquery(owned)
          )
      end

    if enabled?() do
      query
      |> order_by([a], desc: a.updated_at)
      |> limit(500)
      |> preload([:owner, :owner_team, :team, team_grants: :team])
      |> Repo.all()
      |> Enum.map(&admin_row/1)
    else
      []
    end
  end

  @doc """
  One artifact's page as an administrator who may take it down reads it: what `get/3`
  answers its owner, with its versions, who it is shared with by name, its links and its
  comments, a private one too, and whether the administrator may open it as anybody may
  (`may_open`). Never what a file holds, nor its picture. A platform administrator reads
  any; a team's administrator those for their teams and those their teams own; another is
  `not_found`. Audited as `artifact.read`, one row each time.
  """
  @spec admin_get(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def admin_get(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- findable(id, user, admin?),
         true <- oversees?(artifact, user, admin?) do
      artifact = Repo.preload(artifact, [:owner, :owner_team, :team, :versions])

      {:ok, _event} =
        Audit.record(
          user.subject,
          "artifact.read",
          artifact.id,
          %{
            "title" => artifact.title,
            "visibility" => artifact.visibility,
            "owner" => artifact.owner && artifact.owner.subject
          }
          |> Map.reject(fn {_key, value} -> is_nil(value) end)
        )

      {:ok,
       artifact
       |> to_json(user, admin?)
       |> Map.merge(%{
         "thumbnail_url" => nil,
         "retention" => retention(),
         "shares" => Shares.list(artifact),
         "people" => People.list(artifact),
         "thread" => Comments.list(artifact, user, role(artifact, user), true),
         "may_open" => match?({:ok, _artifact}, visible(artifact.id, user, admin?))
       })}
    else
      false -> {:error, Error.new(:not_found, %{id: id})}
      other -> other
    end
  end

  # Whose artifacts an administrator answers for: every one for a platform administrator,
  # and for a team's those for the team and those it owns, as `admin_list/1` lists them.
  defp oversees?(_artifact, _user, true), do: true

  defp oversees?(artifact, user, _admin?),
    do:
      administers?(artifact, user) or
        (is_binary(artifact.owner_team_id) and
           artifact.owner_team_id in Enum.map(administered_teams(user), & &1.id))

  defp admin_row(artifact) do
    %{
      "id" => artifact.id,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      "teams" => Teams.names(artifact),
      "owner" => person(artifact.owner),
      "owner_team" => team_name(artifact.owner_team),
      "team" => team_name(artifact.team),
      "origin" => Map.merge(%{"profile" => artifact.profile}, artifact.origin || %{}),
      "version" => artifact.version,
      "bytes" => artifact.bytes,
      "total_bytes" => artifact.total_bytes,
      "created_at" => artifact.inserted_at,
      "published_at" => artifact.updated_at,
      "goes_at" => Retention.goes_at(artifact, Retention.periods()),
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

  # What one attachment carries at most, every file of it together: under what one message
  # of a daemon's call or a pod's control link carries comfortably once in base64.
  @max_attach 2_000_000

  @doc """
  The files of a version, for a session's workspace (#920): what `fs.upload` with
  `artifact` puts there, on a pod through its control link and on a laptop through its
  daemon's call, so the bytes never pass through the person's client. `path` narrows it to
  one file; `version` is the current one where none is named. Whoever may see it reads it,
  as `read/4`; each file is `{path, content_type, bytes}` with the bytes in base64, and the
  answer names the artifact's `id`, `title` and `version`. A version past what one
  attachment carries is refused with its size.
  """
  @spec files(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def files(id, %User{} = user, params, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)
    n = params["version"]

    with {:ok, artifact} <- visible(id, user, admin?),
         %Version{} = version <- version_of(artifact, if(is_integer(n), do: n, else: :current)),
         {:ok, wanted} <- wanted_files(version, params["path"]),
         :ok <- attachable(wanted),
         {:ok, files} <- read_all(artifact, version, wanted) do
      {:ok,
       %{
         "id" => artifact.id,
         "title" => artifact.title,
         "version" => version.n,
         "files" => files
       }}
    else
      {:error, %Error{}} = error -> error
      _no -> {:error, Error.new(:not_found, %{id: id, version: n, path: params["path"]})}
    end
  end

  defp wanted_files(version, nil), do: {:ok, version.files}

  defp wanted_files(version, path) when is_binary(path) do
    case Enum.filter(version.files, &(&1["path"] == path)) do
      [] -> :error
      one -> {:ok, one}
    end
  end

  defp wanted_files(_version, _path), do: :error

  # A version's stored file records its size as `bytes`; only an announced upload says `size`.
  defp attachable(files) do
    size = files |> Enum.map(&(&1["bytes"] || 0)) |> Enum.sum()

    if size <= @max_attach,
      do: :ok,
      else:
        {:error,
         invalid(
           "the version's files are #{size} bytes together, more than #{@max_attach} attached at once; " <>
             "name one file with path"
         )}
  end

  defp read_all(artifact, version, wanted) do
    Enum.reduce_while(wanted, {:ok, []}, fn entry, {:ok, acc} ->
      case file_of(artifact, version, entry["path"]) do
        {:ok, file, body} ->
          read = %{
            "path" => file["path"],
            "content_type" => file["content_type"],
            "bytes" => Base.encode64(body)
          }

          {:cont, {:ok, [read | acc]}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      :error -> :error
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
  With `person`, no link: the artifact shared with that person by name at `role`, who is
  told. With `team`, the team added to who reads it, as `set_access/4` adds one.
  """
  @spec share(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def share(id, user, params, opts \\ [])

  def share(id, %User{} = user, %{"person" => subject} = params, opts) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "shares"),
         :ok <- sensitive(artifact, {"artifact", %{"person" => subject, "role" => params["role"]}}, user, opts),
         {:ok, granted} <- People.grant(artifact, user, subject, params["role"]) do
      People.told(artifact, user, [subject])
      {:ok, granted}
    end
  end

  def share(id, %User{} = user, %{"team" => name}, opts) when is_binary(name) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "shares"),
         {:ok, _access} <- set_access(id, user, %{"teams" => Enum.uniq(Teams.names(artifact) ++ [name])}, opts),
         do: {:ok, %{"id" => artifact.id, "team" => name}}
  end

  def share(id, %User{} = user, params, opts) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "shares"),
         :ok <- sensitive(artifact, {"link", %{}}, user, opts),
         host when is_binary(host) <- host_url() || {:error, no_host()} do
      Shares.share(artifact, user, params, host)
    end
  end

  @doc """
  Revoke a link (`share`, its id) or one person's use of every link and their grant
  (`person`, a subject), or take a team off who reads it (`team`, its name).
  """
  @spec unshare(String.t(), User.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def unshare(id, user, params, opts \\ [])

  def unshare(id, %User{} = user, %{"team" => name}, opts) when is_binary(name) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "revokes a link to"),
         names = Teams.names(artifact),
         true <- name in names || {:error, Error.new(:not_found, %{team: name})},
         {:ok, _access} <- set_access(id, user, %{"teams" => names -- [name]}, opts),
         do: {:ok, %{"revoked" => true, "id" => artifact.id, "team" => name}}
  end

  def unshare(id, %User{} = user, params, opts) do
    with :ok <- on(),
         {:ok, artifact} <- owned(id, user, Keyword.get(opts, :platform_admin?, false), "revokes a link to") do
      Shares.unshare(artifact, user, params)
    end
  end

  # -- comments ---------------------------------------------------------------------

  @doc "Artifact `id`'s thread, oldest first, for whoever may open it (`Comments`)."
  @spec comments(String.t(), User.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def comments(id, %User{} = user, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with {:ok, artifact} <- visible(id, user, admin?) do
      role = role(artifact, user)

      {:ok,
       %{
         "id" => artifact.id,
         "may_comment" => role in Comments.writers(),
         "max_length" => Comments.max_body(),
         "comments" => Comments.list(artifact, user, role, takes_down?(artifact, user, admin?))
       }}
    end
  end

  @doc "A comment `body` in artifact `id`'s thread, by whoever holds comment, edit or owner on it."
  @spec comment(String.t(), User.t(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def comment(id, %User{} = user, body, opts \\ []) do
    with :ok <- on(),
         {:ok, artifact} <- visible(id, user, Keyword.get(opts, :platform_admin?, false)) do
      Comments.add(artifact, user, role(artifact, user), body)
    end
  end

  @doc """
  Delete comment `comment` from artifact `id`'s thread: its author's, an owner's, or a
  takedown by whoever may take the artifact down (a platform administrator, the
  administrator of the team it is for). Audited without its text.
  """
  @spec delete_comment(String.t(), User.t(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete_comment(id, %User{} = user, comment, opts \\ []) do
    admin? = Keyword.get(opts, :platform_admin?, false)

    with :ok <- on(),
         {:ok, artifact} <- visible(id, user, admin?) do
      Comments.delete(artifact, user, role(artifact, user), takes_down?(artifact, user, admin?), comment)
    end
  end

  @doc "Comment `comment` in artifact `id`'s thread with `body` instead, by its author, marked edited."
  @spec edit_comment(String.t(), User.t(), term(), term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def edit_comment(id, %User{} = user, comment, body, opts \\ []) do
    with :ok <- on(),
         {:ok, artifact} <- visible(id, user, Keyword.get(opts, :platform_admin?, false)) do
      Comments.edit(artifact, user, role(artifact, user), comment, body)
    end
  end

  # Whether `user` may take `artifact` down, as `delete/3` lets them: whoever may do that
  # to the whole artifact may do it to one comment in its thread.
  defp takes_down?(artifact, user, admin?), do: admin? or administers?(artifact, user)

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
         {:ok, entry} <- file_path(artifact, version, path),
         {:ok, file, body} <- file_of(artifact, version, entry) do
      if is_nil(path), do: Retention.touch(artifact)
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
      :ok = Retention.touch(artifact)

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

  @thumbnail_salt "troupe artifact thumbnail"

  # A card's picture address: signed for `user` and the version in force, under a salt of
  # its own, and dated to the start of the hour so a gallery listed twice in one hour asks
  # for the same address. An `<img>` sends no cookie of the artifacts host's, which a
  # gallery has not been given, so the address is the key; who it names is read again when
  # it is fetched.
  defp thumbnail_url(%Artifact{thumbnail: %{}} = artifact, %User{subject: subject}) when is_binary(subject) do
    with host when is_binary(host) <- host_url() do
      hour = div(System.os_time(:second), 3600) * 3600
      claims = %{"s" => subject, "a" => artifact.id, "v" => current(artifact)}
      "#{host}/t/#{Plug.Crypto.sign(secret(), @thumbnail_salt, claims, signed_at: hour)}"
    end
  end

  defp thumbnail_url(_artifact, _user), do: nil

  @doc """
  The picture a card's address (`thumbnail_url` on a row) names, for the artifacts host: its
  content type and bytes, while the person it was made for is active and may still see the
  artifact, read now. `:error` for an address that is forged or past two hours, a person who
  may no longer see it, and a version without one.
  """
  @spec thumbnail(String.t()) :: {:ok, %{content_type: String.t(), body: binary()}} | :error
  def thumbnail(token) when is_binary(token) do
    with {:ok, %{"s" => subject, "a" => id, "v" => n}} when is_integer(n) <-
           Plug.Crypto.verify(secret(), @thumbnail_salt, token, max_age: @thumbnail_seconds),
         %User{} = user <- Identity.get_user(subject),
         true <- user.active != false,
         {:ok, artifact} <- visible(id, user, platform_admin?(user)),
         %Version{thumbnail: %{} = picture} <- version_of(artifact, n),
         {:ok, body} <- ObjectStore.get(store(), thumbnail_key(id, picture["stored_in"] || n)) do
      {:ok, %{content_type: picture["content_type"], body: body}}
    else
      _no -> :error
    end
  end

  def thumbnail(_token), do: :error

  defp nonce, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  # The plane's own secret, with salts of these two alone, so neither a ticket nor the
  # artifacts host's cookie is anything the plane's own cookies would take, or the other way.
  # The endpoint's name is only the key its config is under, so it is made from a string:
  # named as a module, it would tie this module to the endpoint, which compiles against the
  # router, which reaches this module.
  defp secret do
    :troupe_plane
    |> Application.get_env(Module.concat(["Troupe.Plane.Web.Endpoint"]), [])
    |> Keyword.fetch!(:secret_key_base)
  end

  # -- the answer -----------------------------------------------------------------

  @doc false
  @spec to_json(Artifact.t(), User.t(), boolean(), map() | nil) :: map()
  def to_json(%Artifact{} = artifact, %User{} = user, admin?, meta \\ nil) do
    meta = meta || meta_of(artifact, user, admin?)
    mine = meta.role == "owner"

    %{
      "id" => artifact.id,
      "title" => artifact.title,
      "kind" => artifact.kind,
      "visibility" => artifact.visibility,
      # Who reads it beside its owners and the people and links it is shared through: the
      # teams, by name, and whether every signed-in person does.
      "teams" => Teams.names(artifact),
      "organisation" => artifact.visibility == "organisation",
      # The gallery tab it is under: mine, private, organisation, team:<name> (a team of
      # the caller's that reads it) or shared.
      "scope" => meta.scope,
      # The person who published it, and the team it belongs to, if one does: then its
      # owners are that team's people, and `role`, `mine` and `may_delete` say so.
      "owner" => person(artifact.owner),
      "owner_team" => team_name(artifact.owner_team),
      "mine" => mine,
      "role" => meta.role,
      "origin" => Map.merge(%{"profile" => artifact.profile}, artifact.origin || %{}),
      "team" => team_name(artifact.team),
      "version" => artifact.version,
      "current" => current(artifact),
      "pinned" => artifact.pinned,
      "bytes" => artifact.bytes,
      "url" => url(artifact.id),
      # The picture its publisher sent of the version in force, on the artifacts host, for
      # the caller alone; null where none was sent.
      "thumbnail_url" => thumbnail_url(artifact, user),
      # How many references the artifacts host blocks in the version in force, read from its
      # files at publish; `artifact.get` lists them on each version.
      "blocked_count" => artifact.blocked || 0,
      "created_at" => artifact.inserted_at,
      "published_at" => artifact.updated_at,
      "may_delete" => mine or admin? or meta.administers,
      "may_edit" => meta.role in ["owner", "edit"],
      # Whether the caller may write in its thread, and how long the thread is.
      "may_comment" => meta.role in Comments.writers(),
      "comments" => elem(meta.comments, 0),
      "commented_at" => elem(meta.comments, 1),
      # Whether the caller could move whose it is with `artifact.transfer`.
      "may_transfer" => meta.may_transfer,
      # Whether the caller keeps it at the top of their own gallery: theirs alone to say.
      "kept" => Map.get(meta, :kept, false),
      # The owner's switch for its public links, and whether one opens now.
      "public_links" => artifact.public_links != false,
      "public" => meta.public,
      # When it is removed for nobody opening it, or nil where no period says it will be.
      "goes_at" => Retention.goes_at(artifact, Retention.periods())
    }
    |> put_versions(artifact)
  end

  # The administrator's retention periods in days, nil for one that is off.
  defp retention do
    periods = Retention.periods()
    %{"versions_days" => periods.versions, "unopened_days" => periods.unopened}
  end

  @doc false
  # The store artifacts are kept in, for `Retention`'s removals.
  def object_store, do: store()

  defp put_versions(json, %Artifact{versions: versions} = artifact) when is_list(versions) do
    people = versions |> Enum.map(& &1.published_by) |> Enum.uniq() |> people()
    periods = Retention.periods()

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
          "files" => Enum.map(version.files, &Map.drop(&1, ["stored_in", "blocked"])),
          # What the artifacts host blocks in it: `{file, kind, reference, line}`.
          "blocked" => blocked(version.files),
          "published_by" =>
            Map.get(people, version.published_by, %{
              "subject" => version.published_by,
              "display_name" => nil
            }),
          "published_at" => version.published_at,
          "note" => version.note,
          "rolled_back_to" => version.rolled_back_to,
          # When this version is removed for its age; nil for the newest, the pinned one,
          # and every one while that period is off.
          "goes_at" => Retention.version_goes_at(artifact, version, periods),
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
