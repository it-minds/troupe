defmodule Troupe.Commands.Trust do
  @moduledoc """
  Which of a workspace's commands a person has seen and agreed to send unasked
  (Decision 814).

  A `.troupe/commands/<name>.md` arrives with a clone, and its palette row says what its
  frontmatter says. With `auto_approve` off every tool call its prompt leads to asks
  anyway; with it on, nothing stands between running `/review` and the agent doing what
  its body says. So while `auto_approve` is on, a workspace's command asks once before it
  is first sent, showing what it sends (`Troupe.Commands.run/4`), the way a workspace's
  MCP servers ask before they start (Decision 700).

  `allow` is remembered here, per checkout and per command, beside a fingerprint of the
  command's body, so an edited command asks again and what is typed after its name does
  not. The answers live in the state directory, never in the repository: a file the
  repository carried would be the repository approving itself. A git worktree shares its
  checkout's answers, as it shares its trust.
  """

  alias Troupe.MCP.Trust, as: MCPTrust

  @file_name "command-trust.json"

  @doc "Where the answers are kept: `<state>/command-trust.json`."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir \\ nil), do: Path.join(Troupe.Paths.state_dir(state_dir), @file_name)

  @doc "What is remembered of a command: a hash of the prompt its file sends."
  @spec fingerprint(%{body: String.t()}) :: String.t()
  def fingerprint(%{body: body}),
    do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

  @doc "Whether this command, as its file reads now, was allowed in this workspace."
  @spec approved?(Path.t() | nil, Path.t(), %{name: String.t(), body: String.t()}) :: boolean()
  def approved?(state_dir, workspace, %{name: name} = command) do
    state_dir |> load() |> get_in([MCPTrust.key(workspace), name]) == fingerprint(command)
  end

  @doc "Remember that this command, as its file reads now, may be sent in this workspace."
  @spec approve(Path.t() | nil, Path.t(), %{name: String.t(), body: String.t()}) ::
          :ok | {:error, String.t()}
  def approve(state_dir, workspace, %{name: name} = command) do
    all = load(state_dir)
    entry = %{name => fingerprint(command)}
    save(state_dir, Map.update(all, MCPTrust.key(workspace), entry, &Map.merge(&1, entry)))
  end

  defp load(state_dir) do
    with {:ok, text} <- File.read(path(state_dir)),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      Map.new(map, fn {workspace, commands} ->
        {workspace, if(is_map(commands), do: commands, else: %{})}
      end)
    else
      _ -> %{}
    end
  end

  defp save(state_dir, map) do
    file = path(state_dir)

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, Jason.encode!(map, pretty: true) <> "\n") do
      :ok
    else
      {:error, reason} ->
        {:error, "could not write #{Troupe.Paths.display(file)}: #{:file.format_error(reason)}"}
    end
  end
end
