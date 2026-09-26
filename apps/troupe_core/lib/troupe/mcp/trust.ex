defmodule Troupe.MCP.Trust do
  @moduledoc """
  Which of a workspace's own MCP servers a person has agreed to run (Decision 700).

  A `.troupe/mcp.json` in a cloned repository names commands this machine would run
  the moment a session opened, so a workspace-level server runs only once somebody
  attached has said so — through the session's question path, the way an `ask_user`
  is answered, so any client can answer it. `allow` is remembered here, per workspace
  and per server, beside the fingerprint of what would run, so the question comes back
  when the command changes and not when the file is re-ordered. `once` runs the servers
  for that session and remembers nothing; `deny` runs nothing, and the next session
  asks again.

  The answers live in the state directory, never in the repository: a file the
  repository carried would be the repository approving itself. A workspace on the user
  file's `trusted_workspaces` (Decision 686) is never asked, since trusting it already
  lets its `config.yaml` name what runs, and a git worktree shares its checkout's
  answers as it shares its trust.
  """

  alias Troupe.Config.Trust, as: ConfigTrust
  alias Troupe.Workspace

  @file_name "mcp-trust.json"

  @doc "Where the answers are kept: `<state>/mcp-trust.json`."
  @spec path(Path.t() | nil) :: Path.t()
  def path(state_dir \\ nil), do: Path.join(Troupe.Paths.state_dir(state_dir), @file_name)

  @doc "The name a workspace's answers are filed under: its checkout's real path, compared as the platform compares paths."
  @spec key(Path.t()) :: String.t()
  def key(workspace), do: workspace |> ConfigTrust.root() |> Workspace.compare_key()

  @doc "What was approved for a workspace: server name to the fingerprint approved."
  @spec approved(Path.t() | nil, Path.t()) :: %{String.t() => String.t()}
  def approved(state_dir, workspace) do
    state_dir |> load() |> Map.get(key(workspace), %{})
  end

  @doc "Whether this server, as it would run now, was approved for this workspace."
  @spec approved?(Path.t() | nil, Path.t(), %{name: String.t(), fingerprint: String.t()}) ::
          boolean()
  def approved?(state_dir, workspace, %{name: name, fingerprint: fingerprint}) do
    Map.get(approved(state_dir, workspace), name) == fingerprint
  end

  @doc "Remember that these servers may run in this workspace, as they are now."
  @spec approve(Path.t() | nil, Path.t(), [%{name: String.t(), fingerprint: String.t()}]) ::
          :ok | {:error, String.t()}
  def approve(state_dir, workspace, servers) do
    all = load(state_dir)
    entries = Map.new(servers, &{&1.name, &1.fingerprint})
    save(state_dir, Map.update(all, key(workspace), entries, &Map.merge(&1, entries)))
  end

  @doc "Forget every answer for a workspace, so its servers are asked about again."
  @spec forget(Path.t() | nil, Path.t()) :: :ok | {:error, String.t()}
  def forget(state_dir, workspace),
    do: save(state_dir, Map.delete(load(state_dir), key(workspace)))

  defp load(state_dir) do
    with {:ok, text} <- File.read(path(state_dir)),
         {:ok, map} when is_map(map) <- Jason.decode(text) do
      Map.new(map, fn {workspace, servers} ->
        {workspace, if(is_map(servers), do: servers, else: %{})}
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
