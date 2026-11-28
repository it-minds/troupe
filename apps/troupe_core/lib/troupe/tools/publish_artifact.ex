defmodule Troupe.Tools.PublishArtifact do
  @moduledoc """
  Publishes a page, a Markdown document or a file from the workspace as an artifact on the
  plane (#62), for the session's person: theirs alone unless it says otherwise (they share
  it with a link), or read by the teams it names or the whole organisation, in their
  galleries and served from the plane's artifacts host, where it can touch nothing.

  Confined as `remember`'s anchors are: every file a regular file inside the workspace, read
  as it is now. The files keep their paths below the directory they share, so a page's
  relative links to its stylesheet and scripts still resolve. `id` republishes one of the
  person's own: the next version at the same address. `thumbnail`, a picture in the
  workspace (a screenshot the agent already took), goes with the version for its gallery
  card; none is none, and the card shows the kind instead.

  Whom a new one is for is the person's to say, not the model's. A call that names a
  `visibility` or `teams` the person asked for is asked about by default, because what it
  publishes is read by people who were not in this session, and a per-tool rule may allow
  it. A new one that names neither must be asked, whatever a rule or `auto_approve` says
  (`must_ask?/1`): the request carries the publication for the gate to show
  (`publication/2`), with the teams the plane would give it by default ticked, the person
  chooses the audience and whose it is there, and the call runs with what they chose laid
  over its arguments (`as_answered/2`), its answer saying so. A new version keeps who reads
  the artifact and asks nothing about it: the gate shows who that is, in words the plane
  gives, and a call that names an audience for one is refused, since who reads an artifact
  is changed in its Access menu, never by the model. What it published is on the call's
  own event, as `artifact` (`id`, `version`, `url`, and `owner_team` for a team's), and in
  the plane's audit trail with the session. What the artifacts host will block in it (a
  stylesheet from another site, an inline script, a document's image from another site), as
  the plane read it from the files, is in the answer by file and reference, so the agent
  can publish a corrected version.

  Offered only where the host installed somewhere for it to go (`Troupe.Artifacts`). There,
  signed out, it is refused with a sentence naming the file, which the person can open or
  send themselves.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Artifacts, Tool, Workspace}
  alias Troupe.Protocol.Words

  @kinds ~w(html markdown file)
  @owners ~w(me team)
  @visibilities ~w(private organisation)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024
  @max_thumbnail_bytes 256 * 1024

  @impl Troupe.Tool
  def name, do: "publish_artifact"

  @impl Troupe.Tool
  def description do
    """
    Publish a report or page from the workspace for people to read in their organisation's gallery: `html` (a page and its CSS, JS and images), `markdown` (a document, rendered with code highlighting and Mermaid flowcharts), or `file` (one file, as a PDF or an image).

    `files`: workspace paths; they keep their paths below the directory they share, so relative links still work. A page opens `index.html`; a document `index.md` or `README.md`. An artifact may load only its own files: no stylesheet, script, font or image from another site, and no inline script or onclick; put the CSS and JS in files of their own and publish them with the page. In a document, an image from another site (`![](https://...)`) is shown as a sentence naming that site; publish the image beside the document and link it relatively. A page reads its own files only through `<script src>`, `<link>`, `<img>` and the like, never `fetch`, `XMLHttpRequest`, `EventSource` or `import()`, which fail even for its own files; no module scripts (`type="module"`), and a web font only as a `data:` address. To give a script data, publish it as a `.js` file that sets a global and load it with `<script src>` before the script that uses it. The answer names anything the artifacts host will block. Keep it to a few megabytes.

    `thumbnail`: optional, a workspace PNG, JPEG or WebP of at most 256 KiB shown on the gallery card; send one only if you already have a screenshot of the page. Never required.

    Whom a new one is for is the person's to decide, not yours: `visibility` `private` (the person and whoever they share it with) or `organisation`, and `teams`, the names of teams whose members read it. Set them only to what the person asked for; when they did not say, leave them out and they choose at the approval. `owner`: `me` (the default) or `team`, whose a new one is; `team` is the one team in `teams`. `id`: one of yours, or one you were given an edit link to, to publish as the next version at the same address, with `note` saying what changed; the earlier versions are kept, and so is who reads it: never name `visibility`, `teams` or `owner` with `id`.
    """
    |> String.trim()
  end

  @impl Troupe.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "kind" => %{"type" => "string", "enum" => @kinds},
        "visibility" => %{
          "type" => "string",
          "enum" => @visibilities,
          "description" =>
            "A new one's: private or organisation, only what the person asked for; left out, the person chooses at the approval"
        },
        "teams" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "A new one's: the teams whose members read it, only those the person named; left out, the person chooses at the approval"
        },
        "owner" => %{
          "type" => "string",
          "enum" => @owners,
          "description" => "whose a new one is: me (the default), or team, the one team in teams"
        },
        "files" => %{"type" => "array", "items" => %{"type" => "string"}},
        "id" => %{
          "type" => "string",
          "description" =>
            "An artifact of yours, or one you hold an edit link to, to publish a new version of; it keeps who reads it."
        },
        "note" => %{
          "type" => "string",
          "description" => "What changed in this version, in a line."
        },
        "thumbnail" => %{
          "type" => "string",
          "description" => "Optional: a workspace path to a picture of the page for its card (PNG, JPEG or WebP, at most 256 KiB)."
        }
      },
      "required" => ["title", "kind", "files"]
    }
  end

  # Asked, because what it publishes is read by people who were not in this session.
  @impl Troupe.Tool
  def default_permission, do: :ask

  # A new one that says whom it is for is asked as any `ask` tool's, and a rule may allow
  # it; one that says nothing is asked whatever the rules and `auto_approve` say, because
  # the person has not yet said whom it is for, and nobody else may choose that. A new
  # version keeps who reads it, so there is nothing about its audience to ask: the person's
  # rules decide it as any call's.
  @impl Troupe.Tool
  def must_ask?(args), do: not named?(args["id"]) and not aimed?(args)

  @impl Troupe.Tool
  def available?(_session_id), do: Artifacts.reachable?()

  @doc """
  What the gate shows of a call, for the person to aim it: the title, the kind, how many
  files, the audience and the owner as the model proposed them (`nil` where it proposed
  none, and for a republish, whose readers and owner do not change), the artifact it
  republishes and its note.
  """
  @spec publication(map()) :: map()
  def publication(args) do
    republish? = named?(args["id"])

    %{
      "title" => args["title"],
      "kind" => args["kind"],
      "files" => args["files"] |> List.wrap() |> length(),
      "visibility" => if(named?(args["visibility"]) and not republish?, do: args["visibility"]),
      "teams" => if(teams?(args["teams"]) and not republish?, do: args["teams"]),
      "owner" => if(args["owner"] in @owners and not republish?, do: args["owner"]),
      "id" => if(republish?, do: args["id"]),
      "note" => if(named?(args["note"]), do: args["note"])
    }
  end

  @doc """
  `publication/1` with what the plane says of it (`Troupe.Artifacts.about/2`): for a new
  version, who reads the artifact now, in words (`access`), which it keeps; for a new one
  whose call named no teams, the teams the plane gives it by default (`teams`, those granted
  the session's profile on a pod), ticked for the person to keep or change. Where the plane
  says nothing, the publication is as `publication/1` has it.
  """
  @spec publication(map(), Tool.Ctx.t() | map()) :: map()
  def publication(args, ctx) do
    publication = publication(args)

    case Artifacts.about(Map.take(publication, ["id"]), ctx) do
      {:ok, about} -> with_about(publication, about)
      _none -> publication
    end
  end

  defp with_about(%{"id" => id} = publication, %{"access" => access}) when is_binary(id) and is_binary(access),
    do: Map.put(publication, "access", access)

  defp with_about(%{"id" => nil, "teams" => nil} = publication, %{"teams" => [_ | _] = teams}),
    do: Map.put(publication, "teams", teams)

  defp with_about(publication, _about), do: publication

  @doc """
  The call's arguments with what the person chose at the gate laid over them: their
  `visibility`, `teams` and `owner` replace the model's, so the tool publishes for whom they
  said.
  """
  @spec as_answered(map(), map()) :: map()
  def as_answered(args, answer) do
    Map.merge(
      args,
      answer
      |> Map.take(~w(visibility teams owner))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  defp named?(value), do: is_binary(value) and value != ""
  defp teams?(value), do: is_list(value) and value != []
  defp aimed?(args), do: named?(args["visibility"]) or teams?(args["teams"])

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, title} <- Tool.fetch_string(args, "title"),
         {:ok, kind} <- kind(args),
         :ok <- readers_kept(args),
         {:ok, visibility} <- visibility(args),
         {:ok, teams} <- teams(args),
         {:ok, owner} <- owner(args),
         {:ok, paths} <- paths(args),
         {:ok, files} <- read(ctx, paths),
         {:ok, thumbnail} <- thumbnail(ctx, args["thumbnail"]) do
      params =
        %{"title" => title, "kind" => kind, "files" => Enum.map(files, &wire/1)}
        |> put_visibility(visibility)
        |> put_teams(teams)
        |> put_owner(owner, args["id"])
        |> put_id(args["id"])
        |> put_note(args["note"])
        |> put_thumbnail(thumbnail)

      case Artifacts.publish(params, ctx) do
        {:ok, artifact} ->
          {:ok, answer(artifact, files, ctx), %{fields: %{"artifact" => fields(artifact)}}}

        {:error, :signed_out} ->
          {:error,
           "not published: this session's person is not signed in to a Troupe plane here, so there is " <>
             "nowhere to publish it. It is in the workspace at #{Enum.map_join(files, ", ", & &1.source)}; " <>
             "tell them, so they can open it or send it themselves, or ask them to sign in"}

        {:error, reason} ->
          {:error, "not published: #{reason}"}
      end
    end
  end

  defp kind(args) do
    case args["kind"] do
      kind when kind in @kinds -> {:ok, kind}
      other -> {:error, {:invalid_args, "kind is html, markdown or file, not #{inspect(other)}"}}
    end
  end

  # A new version keeps who reads the artifact: the model does not re-aim one it already
  # published, and the person changes its readers in its Access menu.
  defp readers_kept(%{"id" => id} = args) when is_binary(id) and id != "" do
    if aimed?(args),
      do:
        {:error,
         {:invalid_args,
          "a new version keeps who reads the artifact, so name no visibility or teams with id; " <>
            "the person changes who reads it in the artifact's Access menu"}},
      else: :ok
  end

  defp readers_kept(_args), do: :ok

  # None said is the person alone for a new one, and who read it already for a new version
  # of one: reached only by a call nobody was asked about, since the gate lays the person's
  # choice over a call that said nothing.
  defp visibility(%{"visibility" => visibility}) when visibility in @visibilities, do: {:ok, visibility}

  defp visibility(%{"visibility" => other}) when not is_nil(other) and other != "",
    do: {:error, {:invalid_args, "visibility is private or organisation, not #{inspect(other)}"}}

  defp visibility(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, nil}
  defp visibility(_args), do: {:ok, "private"}

  defp put_visibility(params, nil), do: params
  defp put_visibility(params, visibility), do: Map.put(params, "visibility", visibility)

  defp teams(%{"teams" => teams}) when is_list(teams) do
    if Enum.all?(teams, &named?/1),
      do: {:ok, teams},
      else: {:error, {:invalid_args, "teams is a list of teams' names, not #{inspect(teams)}"}}
  end

  defp teams(%{"teams" => other}) when not is_nil(other),
    do: {:error, {:invalid_args, "teams is a list of teams' names, not #{inspect(other)}"}}

  defp teams(_args), do: {:ok, []}

  defp put_teams(params, []), do: params
  defp put_teams(params, teams), do: Map.put(params, "teams", teams)

  # Whose it is: the person's unless told `team`, which the plane resolves to the one team
  # that reads it. Only a new one says: whose an artifact is does not change with a
  # version (the plane refuses an `owner` on a republish; `artifact.transfer` moves one),
  # so a republish sends none, whatever was said.
  defp owner(%{"owner" => owner}) when owner in @owners, do: {:ok, owner}

  defp owner(%{"owner" => other}) when not is_nil(other),
    do: {:error, {:invalid_args, "owner is me or team, not #{inspect(other)}"}}

  defp owner(_args), do: {:ok, nil}

  defp put_owner(params, owner, id) when is_binary(owner) and (not is_binary(id) or id == ""),
    do: Map.put(params, "owner", owner)

  defp put_owner(params, _owner, _id), do: params

  defp paths(%{"files" => [_ | _] = paths}) do
    if Enum.all?(paths, &is_binary/1),
      do: {:ok, paths},
      else: {:error, {:invalid_args, "files is a list of workspace paths"}}
  end

  defp paths(_args),
    do: {:error, {:invalid_args, "files is a list of workspace paths, at least one"}}

  defp put_id(params, id) when is_binary(id) and id != "", do: Map.put(params, "id", id)
  defp put_id(params, _id), do: params

  defp put_note(params, note) when is_binary(note) and note != "",
    do: Map.put(params, "note", note)

  defp put_note(params, _note), do: params

  defp put_thumbnail(params, nil), do: params
  defp put_thumbnail(params, thumbnail), do: Map.put(params, "thumbnail", thumbnail)

  # The card's picture: a file in the workspace, confined as the files are, its type from its
  # name; the plane checks its bytes say the same.
  defp thumbnail(_ctx, none) when none in [nil, ""], do: {:ok, nil}

  defp thumbnail(ctx, path) when is_binary(path) do
    with {:ok, type} <- picture_type(path),
         {:ok, [found]} <- resolve_all(ctx, [path]) do
      case File.read(found.real) do
        {:ok, body} when byte_size(body) > @max_thumbnail_bytes ->
          {:error,
           "#{found.relative} is #{byte_size(body)} bytes, past the #{@max_thumbnail_bytes} a thumbnail may be: " <>
             "send a smaller picture, or none"}

        {:ok, body} ->
          {:ok, %{"content_type" => type, "bytes" => Base.encode64(body)}}

        {:error, reason} ->
          {:error, "#{found.relative} could not be read (#{reason})"}
      end
    end
  end

  defp thumbnail(_ctx, other),
    do: {:error, {:invalid_args, "thumbnail is a workspace path, not #{inspect(other)}"}}

  defp picture_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> {:ok, "image/png"}
      ext when ext in [".jpg", ".jpeg"] -> {:ok, "image/jpeg"}
      ".webp" -> {:ok, "image/webp"}
      _other -> {:error, "#{path} is not a .png, .jpg or .webp picture, which is what a thumbnail is: not published"}
    end
  end

  # Each a regular file inside the workspace, read now; their paths below the directory
  # they share, as the artifact keeps them.
  defp read(ctx, paths) do
    with {:ok, found} <- resolve_all(ctx, paths) do
      base = common_dir(Enum.map(found, & &1.relative))

      found
      |> Enum.reduce_while({:ok, [], 0}, &read_one(&1, &2, base))
      |> case do
        {:ok, files, _total} -> {:ok, Enum.reverse(files)}
        error -> error
      end
    end
  end

  defp read_one(file, {:ok, acc, total}, base) do
    case File.read(file.real) do
      {:ok, body} when byte_size(body) > @max_file_bytes ->
        {:halt,
         {:error,
          "#{file.relative} is #{byte_size(body)} bytes, past the #{@max_file_bytes} a file may be"}}

      {:ok, body} when total + byte_size(body) > @max_version_bytes ->
        {:halt, {:error, "these files are past the #{@max_version_bytes} bytes a version may be"}}

      {:ok, body} ->
        path = file.relative |> String.split("/") |> Enum.drop(length(base)) |> Enum.join("/")

        {:cont,
         {:ok, [%{source: file.relative, path: path, body: body} | acc], total + byte_size(body)}}

      {:error, reason} ->
        {:halt, {:error, "#{file.relative} could not be read (#{reason})"}}
    end
  end

  defp resolve_all(ctx, paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      with {:ok, real} <- Workspace.resolve(ctx.workspace, path, :read),
           true <- Workspace.inside?(ctx.workspace, real),
           true <- File.regular?(real) do
        relative = ctx.workspace |> Workspace.relative(real) |> String.replace("\\", "/")
        {:cont, {:ok, [%{real: real, relative: relative} | acc]}}
      else
        {:error, {:outside_workspace, _}} ->
          {:halt, {:error, "#{path} is outside the workspace: not published"}}

        _ ->
          {:halt, {:error, "#{path} is not a file in the workspace: not published"}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  # The directory every file is under, as segments: none for files at the top.
  defp common_dir(relatives) do
    relatives
    |> Enum.map(&(&1 |> String.split("/") |> Enum.drop(-1)))
    |> Enum.reduce(fn dirs, common ->
      common
      |> Enum.zip(dirs)
      |> Enum.take_while(fn {a, b} -> a == b end)
      |> Enum.map(&elem(&1, 0))
    end)
  end

  # The type is the plane's to give, from the path, as it serves the file.
  defp wire(file),
    do: %{"path" => file.path, "bytes" => Base.encode64(file.body)}

  # `owner_team` where the plane answers it: whose the artifact is, when a team's.
  defp fields(artifact),
    do: Map.take(artifact, ["id", "version", "url", "title", "visibility", "teams", "owner_team"])

  # The model is told when the audience is the person's choice rather than its own, so it
  # does not take its proposal for what happened.
  defp answer(artifact, files, ctx) do
    where = artifact["url"] || "the console's Artifacts page"
    chose = if chosen?(ctx), do: ", as the person chose", else: ""

    "published #{artifact["kind"] || "artifact"} \"#{artifact["title"]}\" (#{length(files)} file#{if length(files) == 1, do: "", else: "s"}) " <>
      "as #{artifact["id"]} version #{artifact["version"]}, for #{audience(artifact)}#{chose}, at #{where}. " <>
      blocked(artifact["blocked"], artifact["id"])
  end

  # What the artifacts host will block of the version, as the plane read it from the files:
  # said while the agent can still publish it corrected.
  defp blocked([_ | _] = found, id) do
    "The artifacts host will block #{length(found)} reference#{if length(found) == 1, do: "", else: "s"}: " <>
      Enum.map_join(found, "; ", &blocked_one/1) <>
      ". An artifact may load only its own files#{reads(found)}; publish a corrected version with id #{id}"
  end

  defp blocked(_none, id), do: "Republish it with id #{id}"

  # A read fails even for the page's own file, so the way it can read one is said with it.
  defp reads(found) do
    if Enum.any?(found, &(&1["kind"] == "read")),
      do:
        ", and only through `<script src>`, `<link rel=\"stylesheet\">`, `<img>` and the like " <>
          "(data a script needs goes in a `.js` file that sets a global)",
      else: ""
  end

  defp blocked_one(found) do
    line = if is_integer(found["line"]), do: ", line #{found["line"]}", else: ""
    "#{found["file"]}: #{found["reference"]} (#{blocked_kind(found["kind"])}#{line})"
  end

  defp blocked_kind("stylesheet"), do: "a stylesheet from another site"
  defp blocked_kind("script"), do: "a script from another site"
  defp blocked_kind("image"), do: "an image from another site"
  defp blocked_kind("font"), do: "a font from another site"
  defp blocked_kind("media"), do: "a sound or film from another site"
  defp blocked_kind("frame"), do: "a page from another site in a frame"
  defp blocked_kind("object"), do: "an embedded object, which the host never runs"
  defp blocked_kind("connect"), do: "a connection to another site"

  defp blocked_kind("read"),
    do:
      "a read by fetch, XMLHttpRequest, EventSource, import(), a module or a web font, which fails here even for the page's own file"
  defp blocked_kind("inline_script"), do: "an inline script"
  defp blocked_kind("event_handler"), do: "an inline event handler"
  defp blocked_kind(other), do: to_string(other)

  defp chosen?(%{answer: %{"edited" => [_ | _]}}), do: true
  defp chosen?(_ctx), do: false

  # Whom it is for, as the plane answered it: a new version is for whoever read it before.
  defp audience(%{"version" => n}) when is_integer(n) and n > 1, do: "the readers it already had"
  defp audience(%{"visibility" => "organisation"}), do: "the whole organisation"

  defp audience(%{"teams" => [_ | _] = teams}),
    do: "the members of " <> Words.and_list(Enum.map(teams, &"team #{&1}"))

  defp audience(_private), do: "the person alone, until they share a link to it"
end
