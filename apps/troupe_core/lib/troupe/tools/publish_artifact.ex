defmodule Troupe.Tools.PublishArtifact do
  @moduledoc """
  Publishes a page, a Markdown document or a file from the workspace as an artifact on the
  plane (#62), for the session's person: theirs alone unless it says otherwise (they share
  it with a link), or the organisation's, a team's members' or a profile's people's, read in
  their galleries and served from the plane's artifacts host, where it can touch nothing.

  Confined as `remember`'s anchors are: every file a regular file inside the workspace, read
  as it is now. The files keep their paths below the directory they share, so a page's
  relative links to its stylesheet and scripts still resolve. `id` republishes one of the
  person's own: the next version at the same address.

  Whom it is for is the person's to say, not the model's. A call that names a `visibility`
  the person asked for is asked about by default, because what it publishes is read by
  people who were not in this session, and a per-tool rule may allow it. A call that names
  none must be asked, whatever a rule or `auto_approve` says (`must_ask?/1`): the request
  carries the publication for the gate to show (`publication/1`), the person chooses the
  audience and whose it is there, and the call runs with what they chose laid over its
  arguments (`as_answered/2`), its answer saying so. What it published is on the call's own
  event, as `artifact` (`id`, `version`, `url`, and `owner_team` for a team's), and in the
  plane's audit trail with the session.

  Offered only where the host installed somewhere for it to go (`Troupe.Artifacts`). There,
  signed out, it is refused with a sentence naming the file, which the person can open or
  send themselves.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Artifacts, Tool, Workspace}

  @kinds ~w(html markdown file)
  @owners ~w(me team)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024

  @impl Troupe.Tool
  def name, do: "publish_artifact"

  @impl Troupe.Tool
  def description do
    """
    Publish a report or page from the workspace for people to read in their organisation's gallery: `html` (a page and its CSS, JS and images), `markdown` (a document, rendered with code highlighting and Mermaid flowcharts), or `file` (one file, as a PDF or an image).

    `files`: workspace paths; they keep their paths below the directory they share, so relative links still work. A page opens `index.html`; a document `index.md` or `README.md`. Pages run sandboxed: scripts only from the artifact's own .js files (no inline script), and nothing outside the artifact can be fetched. Keep it to a few megabytes.

    `visibility`: whom it is for, which is the person's to decide, not yours: `private` (the person alone, until they share a link), `organisation`, `team:<name>` for a team's members, or `profile:<name>` for a profile's people. Set it only to what the person asked for; when they did not say, leave it out and they choose at the approval. `owner`: `me` or `team`, whose the artifact is, for a new one; a team publication is the team's unless `owner` is `me`, and a new version keeps its owner. `id`: one of yours, or one you were given an edit link to, to publish as the next version at the same address, with `note` saying what changed; the earlier versions are kept.
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
          "description" =>
            "private, organisation, team:<name> or profile:<name>: only what the person asked for; " <>
              "left out, the person chooses at the approval"
        },
        "owner" => %{
          "type" => "string",
          "enum" => @owners,
          "description" =>
            "whose it is: me, or team for a team:<name> publication (the default there)"
        },
        "files" => %{"type" => "array", "items" => %{"type" => "string"}},
        "id" => %{
          "type" => "string",
          "description" =>
            "An artifact of yours, or one you hold an edit link to, to publish a new version of."
        },
        "note" => %{
          "type" => "string",
          "description" => "What changed in this version, in a line."
        }
      },
      "required" => ["title", "kind", "files"]
    }
  end

  # Asked, because what it publishes is read by people who were not in this session.
  @impl Troupe.Tool
  def default_permission, do: :ask

  # A call that says whom it is for is asked as any `ask` tool's, and a rule may allow it;
  # one that says nothing is asked whatever the rules and `auto_approve` say, because the
  # person has not yet said whom it is for, and nobody else may choose that.
  @impl Troupe.Tool
  def must_ask?(args), do: not named?(args["visibility"])

  @impl Troupe.Tool
  def available?(_session_id), do: Artifacts.reachable?()

  @doc """
  What the gate shows of a call, for the person to aim it: the title, the kind, how many
  files, the audience and the owner as the model proposed them (`nil` where it proposed
  none, and for a republish, whose owner does not change), the artifact it republishes and
  its note.
  """
  @spec publication(map()) :: map()
  def publication(args) do
    %{
      "title" => args["title"],
      "kind" => args["kind"],
      "files" => args["files"] |> List.wrap() |> length(),
      "visibility" => if(named?(args["visibility"]), do: args["visibility"]),
      "owner" => if(args["owner"] in @owners and not named?(args["id"]), do: args["owner"]),
      "id" => if(named?(args["id"]), do: args["id"]),
      "note" => if(named?(args["note"]), do: args["note"])
    }
  end

  @doc """
  The call's arguments with what the person chose at the gate laid over them: their
  `visibility` and `owner` replace the model's, so the tool publishes for whom they said.
  """
  @spec as_answered(map(), map()) :: map()
  def as_answered(args, answer) do
    Map.merge(
      args,
      answer
      |> Map.take(~w(visibility owner))
      |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
  end

  defp named?(value), do: is_binary(value) and value != ""

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, title} <- Tool.fetch_string(args, "title"),
         {:ok, kind} <- kind(args),
         {:ok, visibility} <- visibility(args),
         {:ok, owner} <- owner(args),
         {:ok, paths} <- paths(args),
         {:ok, files} <- read(ctx, paths) do
      params =
        %{"title" => title, "kind" => kind, "files" => Enum.map(files, &wire/1)}
        |> put_visibility(visibility)
        |> put_owner(owner, args["id"])
        |> put_id(args["id"])
        |> put_note(args["note"])

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

  # None said is the person alone for a new one, and who it was for already for a new
  # version of one: reached only by a call nobody was asked about, since the gate lays the
  # person's choice over a call that said nothing.
  defp visibility(%{"visibility" => visibility}) when is_binary(visibility) and visibility != "",
    do: {:ok, visibility}

  defp visibility(%{"visibility" => other}) when not is_nil(other) and other != "",
    do: {:error, {:invalid_args, "visibility is a string, not #{inspect(other)}"}}

  defp visibility(%{"id" => id}) when is_binary(id) and id != "", do: {:ok, nil}
  defp visibility(_args), do: {:ok, "private"}

  defp put_visibility(params, nil), do: params
  defp put_visibility(params, visibility), do: Map.put(params, "visibility", visibility)

  # Whose it is: the plane makes a team publication the team's unless told `me`, so none
  # said is left to it. Only a new one says: whose an artifact is does not change with a
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
    do: Map.take(artifact, ["id", "version", "url", "title", "visibility", "owner_team"])

  # The model is told when the audience is the person's choice rather than its own, so it
  # does not take its proposal for what happened.
  defp answer(artifact, files, ctx) do
    where = artifact["url"] || "the console's Artifacts page"
    chose = if chosen?(ctx), do: ", as the person chose", else: ""

    "published #{artifact["kind"] || "artifact"} \"#{artifact["title"]}\" (#{length(files)} file#{if length(files) == 1, do: "", else: "s"}) " <>
      "as #{artifact["id"]} version #{artifact["version"]}, for #{audience(artifact["visibility"])}#{chose}, at #{where}. " <>
      "Republish it with id #{artifact["id"]}"
  end

  defp chosen?(%{answer: %{"edited" => [_ | _]}}), do: true
  defp chosen?(_ctx), do: false

  defp audience("private"), do: "the person alone, until they share a link to it"
  defp audience("organisation"), do: "the whole organisation"
  defp audience("team:" <> name), do: "team #{name}'s members"
  defp audience("profile:" <> name), do: "profile #{name}'s people"
  defp audience(other), do: to_string(other)
end
