defmodule Troupe.Commands.Local do
  @moduledoc """
  The commands a person or a repository defines, as markdown files (Decision 763).

      <config>/commands/<name>.md               the user's, in every workspace
      <workspace>/.troupe/commands/<name>.md    the workspace's, committed with it

  The file name is the command: `review.md` is `/review`. The file has the shape other
  tools' command files have — optional YAML frontmatter, then the body — so one written
  for another tool reads here as it is. The frontmatter's `description` is what a palette
  shows, `argument-hint` what its usage line says follows the name, and `agent` the agent
  it runs on where a client starts a branch for it (the terminal client's command mode,
  TUI Decision 155); other keys are left alone. The body is the prompt the command sends,
  with `$ARGUMENTS` standing for whatever was typed after the name (`expand/2`).

  The layers resolve the way the skills' do (Decision 700): the workspace's command wins
  over the user's of the same name. A command is a prompt, sent only when somebody types
  it, and does nothing the same words typed by hand would not, so a workspace's are read
  whether or not the workspace is trusted, as its `.troupe/agents/` are.

  A workspace's are held to it by where each file really is, as its agents are
  (Decision 829): a file that is a link out of the workspace, or a `.troupe/commands`
  that is one, is not read, and `skipped/1` says so.
  """

  alias Troupe.Agent.Definitions
  alias Troupe.Protocol.AgentDefinition
  alias Troupe.Workspace

  require Logger

  @type layer :: :user | :project

  @typedoc "One command as its file defines it."
  @type command :: %{
          name: String.t(),
          description: String.t(),
          hint: String.t() | nil,
          agent: String.t() | nil,
          body: String.t(),
          layer: layer(),
          path: Path.t()
        }

  @placeholder "$ARGUMENTS"

  @doc "The user's commands directory, beside `config.yaml`."
  @spec user_dir(keyword()) :: Path.t()
  def user_dir(opts \\ []),
    do: Keyword.get(opts, :user_dir) || Path.join(Troupe.Paths.config_dir(), "commands")

  @doc "A workspace's `.troupe/commands`."
  @spec workspace_dir(Path.t()) :: Path.t()
  def workspace_dir(workspace), do: Path.join(Troupe.Paths.project_dir(workspace), "commands")

  @doc """
  Every command the two layers give a workspace, by name, the workspace's over the
  user's, sorted by name. A file whose name is not one a command may have, whose
  frontmatter is not YAML, or whose body is empty is skipped with a warning.
  """
  @spec list(Path.t(), keyword()) :: [command()]
  def list(workspace, opts \\ []) do
    (in_dir(user_dir(opts), :user) ++ in_workspace(workspace))
    |> Enum.reduce(%{}, fn command, acc -> Map.put(acc, command.name, command) end)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  The workspace's command files that are not read because they are really outside it,
  links followed, each with why, shaped as `Troupe.Agent.Definitions.skipped/1` gives an
  agent: a `.troupe/commands` that is a link out is one entry with no name.
  """
  @spec skipped(Path.t()) :: [Definitions.skipped()]
  def skipped(workspace) do
    dir = workspace_dir(workspace)

    case Workspace.files_within(dir, ".md", workspace) do
      :outside -> [skip(nil, dir)]
      {_inside, outside} -> Enum.map(outside, &skip(Path.basename(&1, ".md"), Path.join(dir, &1)))
    end
  end

  defp skip(name, path),
    do: %{kind: :command, name: name, path: path, reason: Definitions.outside_workspace()}

  @doc """
  The prompt a command sends: its body with every `$ARGUMENTS` replaced by what was typed
  after the name, trimmed. A body without the placeholder has what was typed added as a
  paragraph of its own, so nothing typed is dropped.
  """
  @spec expand(command(), String.t() | nil) :: String.t()
  def expand(%{body: body}, arguments) do
    arguments = String.trim(arguments || "")

    cond do
      String.contains?(body, @placeholder) -> String.replace(body, @placeholder, arguments)
      arguments == "" -> body
      true -> body <> "\n\n" <> arguments
    end
  end

  @doc "Whether a command takes something after its name: it has a hint, or a placeholder."
  @spec takes_arguments?(command()) :: boolean()
  def takes_arguments?(%{body: body, hint: hint}),
    do: hint != nil or String.contains?(body, @placeholder)

  defp in_workspace(workspace) do
    dir = workspace_dir(workspace)

    case Workspace.files_within(dir, ".md", workspace) do
      :outside -> []
      {inside, _outside} -> Enum.flat_map(inside, &read(Path.join(dir, &1), :project))
    end
  end

  defp in_dir(dir, layer) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.flat_map(&read(Path.join(dir, &1), layer))

      {:error, _} ->
        []
    end
  end

  defp read(path, layer) do
    name = Path.basename(path, ".md")

    with :ok <- valid_name(name),
         {:ok, text} <- File.read(path),
         {:ok, meta, body} <- parse(text),
         :ok <- has_body(body) do
      [
        %{
          name: name,
          description: text_of(meta["description"]) || "",
          hint: text_of(meta["argument-hint"]),
          agent: text_of(meta["agent"]),
          body: body,
          layer: layer,
          path: path
        }
      ]
    else
      {:error, reason} ->
        Logger.warning("troupe: skipping command #{path}: #{describe(reason)}")
        []
    end
  end

  defp valid_name(name) do
    if AgentDefinition.valid_name?(name),
      do: :ok,
      else:
        {:error, "#{inspect(name)} is not a command name: lower-case letters, digits and dashes"}
  end

  defp parse(text) do
    {frontmatter, body} = AgentDefinition.split_frontmatter(text)

    with {:ok, meta} <- meta(frontmatter), do: {:ok, meta, String.trim(body)}
  end

  defp meta(""), do: {:ok, %{}}

  defp meta(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, "its frontmatter is not YAML: #{describe(reason)}"}
    end
  end

  defp has_body(""), do: {:error, "it has no prompt to send"}
  defp has_body(_body), do: :ok

  defp text_of(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text_of(value) when is_number(value), do: to_string(value)
  defp text_of(_value), do: nil

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_exception(reason), do: Exception.message(reason)
  defp describe(reason) when is_atom(reason), do: to_string(:file.format_error(reason))
  defp describe(reason), do: inspect(reason)
end
