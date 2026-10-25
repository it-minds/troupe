defmodule Troupe.Tools.PublishArtifact do
  @moduledoc """
  Publishes a page, a Markdown document or a file from the workspace as an artifact on the
  plane (#62), for the session's person: the organisation or a profile's people read it in
  the console's gallery, served from the plane's artifacts host, where it can touch nothing.

  Confined as `remember`'s anchors are: every file a regular file inside the workspace, read
  as it is now. The files keep their paths below the directory they share, so a page's
  relative links to its stylesheet and scripts still resolve. `id` republishes one of the
  person's own: the next version at the same address.

  Asked about by default, because what it publishes is read by people who were not in this
  session; a per-tool rule may allow it. What it published is on the call's own event, as
  `artifact` (`id`, `version`, `url`), and in the plane's audit trail with the session.

  Offered only where the host installed somewhere for it to go (`Troupe.Artifacts`). There,
  signed out, it is refused with a sentence naming the file, which the person can open or
  send themselves.
  """

  @behaviour Troupe.Tool

  alias Troupe.{Artifacts, Tool, Workspace}

  @kinds ~w(html markdown file)
  @max_file_bytes 16 * 1024 * 1024
  @max_version_bytes 64 * 1024 * 1024

  @impl Troupe.Tool
  def name, do: "publish_artifact"

  @impl Troupe.Tool
  def description do
    """
    Publish a report or page from the workspace for people to read in their organisation's gallery: `html` (a page and its CSS, JS and images), `markdown` (a document, rendered with code highlighting and Mermaid flowcharts), or `file` (one file, as a PDF or an image).

    `files`: workspace paths; they keep their paths below the directory they share, so relative links still work. A page opens `index.html`; a document `index.md` or `README.md`. Pages run sandboxed: scripts only from the artifact's own .js files (no inline script), and nothing outside the artifact can be fetched. Keep it to a few megabytes.

    `visibility`: `organisation`, or `profile:<name>` for the people a profile is granted to. `id`: one of yours, or one you were given an edit link to, to publish as the next version at the same address, with `note` saying what changed; the earlier versions are kept.
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
        "visibility" => %{"type" => "string", "description" => "organisation, or profile:<name>"},
        "files" => %{"type" => "array", "items" => %{"type" => "string"}},
        "id" => %{
          "type" => "string",
          "description" => "An artifact of yours, or one you hold an edit link to, to publish a new version of."
        },
        "note" => %{"type" => "string", "description" => "What changed in this version, in a line."}
      },
      "required" => ["title", "kind", "visibility", "files"]
    }
  end

  # Asked, because what it publishes is read by people who were not in this session.
  @impl Troupe.Tool
  def default_permission, do: :ask

  @impl Troupe.Tool
  def available?(_session_id), do: Artifacts.reachable?()

  @impl Troupe.Tool
  def run(args, ctx) do
    with {:ok, title} <- Tool.fetch_string(args, "title"),
         {:ok, kind} <- kind(args),
         {:ok, visibility} <- Tool.fetch_string(args, "visibility"),
         {:ok, paths} <- paths(args),
         {:ok, files} <- read(ctx, paths) do
      params =
        %{
          "title" => title,
          "kind" => kind,
          "visibility" => visibility,
          "files" => Enum.map(files, &wire/1)
        }
        |> put_id(args["id"])
        |> put_note(args["note"])

      case Artifacts.publish(params, ctx) do
        {:ok, artifact} ->
          {:ok, answer(artifact, files), %{fields: %{"artifact" => fields(artifact)}}}

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

  defp paths(%{"files" => [_ | _] = paths}) do
    if Enum.all?(paths, &is_binary/1),
      do: {:ok, paths},
      else: {:error, {:invalid_args, "files is a list of workspace paths"}}
  end

  defp paths(_args),
    do: {:error, {:invalid_args, "files is a list of workspace paths, at least one"}}

  defp put_id(params, id) when is_binary(id) and id != "", do: Map.put(params, "id", id)
  defp put_id(params, _id), do: params

  defp put_note(params, note) when is_binary(note) and note != "", do: Map.put(params, "note", note)
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

  defp fields(artifact), do: Map.take(artifact, ["id", "version", "url", "title", "visibility"])

  defp answer(artifact, files) do
    where = artifact["url"] || "the console's Artifacts page"

    "published #{artifact["kind"] || "artifact"} \"#{artifact["title"]}\" (#{length(files)} file#{if length(files) == 1, do: "", else: "s"}) " <>
      "as #{artifact["id"]} version #{artifact["version"]}, for #{audience(artifact["visibility"])}, at #{where}. " <>
      "Republish it with id #{artifact["id"]}"
  end

  defp audience("organisation"), do: "the whole organisation"
  defp audience("profile:" <> name), do: "profile #{name}'s people"
  defp audience(other), do: to_string(other)
end
