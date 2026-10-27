defmodule Troupe.Instructions.Harness do
  @moduledoc """
  Troupe's own word to every root agent, read before the organisation's memory and every
  instruction file: where a file the person asks for goes (issue #765).

  A fixed paragraph, the same in every session, says the order: where the organisation keeps
  files, if a tool of this session does that; else an artifact on the plane; else the
  workspace, the file said with `write_file`'s `deliverable` so the person's client offers
  to save it. What the person says, or an instruction read after this one, decides outright;
  when more than one way is open and the person named none, the agent asks once.

  After it, per session, what is open here, so the model is not guessing: the tools that
  store files (a server marked `stores: files`, or a person's offered tool marked `files`;
  nothing is inferred from a tool's name), whether `publish_artifact` can publish from this
  session, and the workspace, which always can, said as it is on a laptop (the file is
  already on the person's machine) and on a pod (the client saves it from there).

  Pure: what is open is given.
  """

  @paragraph """
  # Where a file goes
  When the person asks for a file (a document, a report, a spreadsheet, a page), put it first where the organisation keeps files, if a tool here does that; else publish it as an artifact people can share; else make it in the workspace with `write_file` and `deliverable: true`, and say where it is, so their client can save it. What the person says, or an instruction after this one, decides outright. When none of it is clear, more than one way being open and the person naming none, ask one question with `ask_user`, the open ways as its options in this order, and go on with the answer.\
  """

  @typedoc """
  What is open in a session: the tools that store files (by the name the model calls), and
  for an artifact `:open`, `{:closed, why}` (a sentence) or `:none` where nothing here
  publishes one; `where` is `:local` for a session on the person's machine, `:pod` for one
  on a server.
  """
  @type open :: %{
          file_tools: [String.t()],
          artifact: :open | :none | {:closed, String.t()},
          where: :local | :pod
        }

  @doc "The fixed paragraph, as every root agent's prompt carries it."
  @spec paragraph() :: String.t()
  def paragraph, do: @paragraph

  @doc "The paragraph and what is open in this session after it: the harness layer's text."
  @spec text(open()) :: String.t()
  def text(%{} = open) do
    Enum.join([@paragraph, "Open in this session:", store_line(open), artifact_line(open), workspace_line(open)], "\n")
  end

  @doc """
  What is open, as `instructions_loaded` lists it beside the layer: `file_tools`, `artifact`
  (`open`, `none`, or `closed` with `why`) and `where` (`local` or `pod`), so the log says
  which ways each turn was told of.
  """
  @spec json(open()) :: map()
  def json(%{file_tools: tools, artifact: artifact, where: where}) do
    artifact =
      case artifact do
        {:closed, why} -> %{"state" => "closed", "why" => why}
        state -> %{"state" => to_string(state)}
      end

    %{"file_tools" => tools, "artifact" => artifact, "where" => to_string(where)}
  end

  @doc """
  The tools of a list that store files: an MCP server's tool its config marks so (`files`
  on the tool, from the server's `stores: files`), or a person's offered tool their client
  marked `files`. By name, in the list's order.
  """
  @spec file_tools([Troupe.Tool.handle()]) :: [String.t()]
  def file_tools(tools) do
    for tool <- tools, stores_files?(tool), do: Troupe.Tool.name(tool)
  end

  defp stores_files?(%{files: true}), do: true
  defp stores_files?(_tool), do: false

  defp store_line(%{file_tools: []}), do: "- where the organisation keeps files: no tool here does that"

  defp store_line(%{file_tools: names}),
    do: "- where the organisation keeps files: " <> Enum.map_join(names, ", ", &"`#{&1}`")

  defp artifact_line(%{artifact: :open}), do: "- an artifact: `publish_artifact`"
  defp artifact_line(%{artifact: {:closed, why}}), do: "- an artifact: not from here, #{why}"
  defp artifact_line(%{artifact: :none}), do: "- an artifact: not from here, no plane publishes one"

  defp workspace_line(%{where: :local}),
    do: "- the workspace, always: this session runs on the person's machine, so the file is already there"

  defp workspace_line(%{where: :pod}),
    do: "- the workspace, always: this session runs on a server, and their client saves the file from there"
end
