defmodule Troupe.Session do
  @moduledoc """
  One session: a log, an approval gate, client-hosted tools, a root agent, and a watcher.

  `rest_for_one` orders those by dependency. `Log` first, because everything persists
  through it and everything after it must replay if it restarts. `Approvals` next, then
  `ClientTools` — both above the agent, so a restarted agent comes back to the same
  answered approvals and the same registered client tools rather than asking again or
  silently losing them. Then the root `Agent.Node`. Then `Session.Watcher` **last**, so a
  watch-mode crash restarts nothing above it — the guarantee that file watching can never
  disturb a running agent comes from this ordering, not from care inside the watcher.
  `Session.Loop`, which runs `/loop`, is below the agent for the same reason.
  """

  use Supervisor

  alias Troupe.Agent.Definitions
  alias Troupe.{Config, Mounts, Registry, Skills, Workspace}
  alias Troupe.LLM.Fake
  alias Troupe.LLM.Provider

  @root_path ["root"]

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Supervisor.start_link(__MODULE__, opts, name: Registry.session(session_id))
  end

  @doc "The root agent's path. Everything else hangs below it."
  @spec root_path() :: [String.t()]
  def root_path, do: @root_path

  @impl Supervisor
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    workspace = Keyword.fetch!(opts, :workspace)
    config = Keyword.fetch!(opts, :config)
    definitions = Keyword.fetch!(opts, :definitions)

    Process.set_label("troupe session #{session_id}")

    agent_opts = [
      session_id: session_id,
      agent_path: @root_path,
      workspace: workspace,
      config: config,
      definitions: definitions,
      profile: Keyword.get(opts, :profile, config.default_agent),
      task: Keyword.get(opts, :task),
      bundle: Keyword.get(opts, :bundle),
      fake: fake_server(session_id, config, opts),
      restart: :permanent
    ]

    children =
      [
        {Troupe.Session.Log,
         session_id: session_id, workspace_root: workspace.root_real, state_dir: config.state_dir},
        {Troupe.Session.Approvals,
         session_id: session_id,
         auto_approve: config.auto_approve,
         mode: config.approvals,
         managed_rules_only: config.managed_permission_rules_only},
        # The other half of the gate: what the agent asks a person, and the answers.
        # Unattended in the same mode as approvals, since the same nobody is there.
        {Troupe.Session.Questions, session_id: session_id, mode: config.approvals},
        # Above the agent on purpose: a client's registration must survive an agent
        # restart, because the connection that made it has not gone anywhere and would
        # have no way of knowing it needed to offer its tools again.
        {Troupe.Session.ClientTools,
         session_id: session_id, managed_servers_only: config.managed_mcp_servers_only},
        # The workspace's own MCP servers (Decision 654), started with the session and
        # gone with it. Above the agent, since their tools are in its list.
        {Troupe.Session.MCP,
         session_id: session_id, workspace: workspace.root_real, servers: config.mcp}
      ] ++
        fake_child(session_id, config, opts) ++
        [
          {Troupe.Agent.Node, agent_opts},
          {Troupe.Session.Watcher,
           session_id: session_id,
           workspace: workspace,
           agent_path: @root_path,
           enabled: config.watch,
           debounce_ms: config.watch_debounce_ms,
           poll_interval_ms: config.watch_poll_interval_ms},
          # Separate from watch mode, and not optional where it is on: this is how a
          # client attached to a remote session learns that `shell` wrote something.
          {Troupe.Session.Files,
           session_id: session_id,
           workspace: workspace,
           agent_path: @root_path,
           enabled: config.fs_events,
           debounce_ms: config.fs_debounce_ms},
          # `/loop` (Decision 681): after the agent it drives, and after the watchers, so
          # a loop that crashes restarts none of them.
          {Troupe.Session.Loop, session_id: session_id, config: config},
          # Last, and deliberately so: a projection is a subscriber, and one that could
          # restart an agent by crashing would be worse than no projection at all.
          {Troupe.Session.Summary, session_id: session_id}
        ]

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 3, max_seconds: 10)
  end

  # A caller that passed its own scripted model (the test suite) keeps it. Otherwise
  # `provider: "fake"` plus a script file starts one per session, which is how a
  # packaged binary is smoke-tested with no model behind it.
  defp fake_child(session_id, config, opts) do
    if own_fake?(config, opts) do
      [{Fake, [name: Registry.fake(session_id)] ++ fake_script(config)}]
    else
      []
    end
  end

  defp fake_server(session_id, config, opts) do
    cond do
      Keyword.get(opts, :fake) -> Keyword.fetch!(opts, :fake)
      own_fake?(config, opts) -> Registry.fake(session_id)
      true -> nil
    end
  end

  defp own_fake?(config, opts) do
    config.provider in ["fake", :fake] and is_nil(Keyword.get(opts, :fake))
  end

  defp fake_script(%{fake_script: nil}), do: []

  defp fake_script(%{fake_script: path}) do
    if File.regular?(path) do
      Fake.load_script!(path)
    else
      raise ArgumentError, "TROUPE_FAKE_SCRIPT points at #{path}, which does not exist"
    end
  end

  @doc """
  Assemble the options a session needs from a workspace path and user overrides.

  Kept here rather than in the client API so the CLI, the tests and `resume` all
  build a session the same way.

  `:bundle` is the config bundle the session is pinned to, `%{version, hash, channel,
  dir}`, which a worker passes and a laptop never does. Its `dir` is where agent
  definitions of source `:bundle` come from and where the `skills:/` mount points.
  `:kind` says whether this is a `:team` session on a pod or a `:local` one, and
  `:origin` says what started it; both are recorded in `session_created` and nothing
  else reads them.
  """
  @spec build_opts(keyword()) :: {:ok, keyword()} | {:error, term()}
  def build_opts(opts) do
    workspace_path = Keyword.get(opts, :workspace, File.cwd!())
    bundle = Keyword.get(opts, :bundle)

    with {:ok, workspace} <- open_workspace(workspace_path, opts),
         {:ok, config} <- config(workspace, opts),
         :ok <- known_provider(config) do

      # A local session has only `session:/` and this is exactly what `Workspace.new/1`
      # already gave it. A session on a pod arrives with its team volume and possibly
      # the org volume, resolved by the plane from the team's grant — and, when its
      # bundle carries skills, a read-only `skills:/` beside them.
      workspace =
        (Keyword.get(opts, :mounts) || workspace.mounts)
        |> with_skills(bundle)
        |> then(&Workspace.with_mounts(workspace, &1))

      definitions =
        Keyword.get_lazy(opts, :definitions, fn ->
          Definitions.load(workspace.root_real,
            bundle_dir: bundle && bundle[:dir],
            entitled: entitled_agents(bundle),
            acp_agents: acp_agents(bundle)
          )
        end)

      {:ok,
       [
         session_id: Keyword.get_lazy(opts, :session_id, &generate_id/0),
         workspace: workspace,
         config: config,
         definitions: definitions,
         profile: Keyword.get(opts, :agent) || config.default_agent,
         task: Keyword.get(opts, :task),
         fake: Keyword.get(opts, :fake),
         bundle: bundle,
         kind: Keyword.get(opts, :kind, :local),
         origin: Keyword.get(opts, :origin),
         # A pod is told whose session this is; a daemon is not, and works it out from
         # whoever has linked their identity to it.
         owner: Keyword.get(opts, :owner),
         # The session this one branches from, when a client made it as a branch of
         # another (Decision 646). Recorded, listed, filtered on; nothing else.
         parent: Keyword.get(opts, :parent)
       ]}
    end
  end

  # A file Troupe refuses is an answer to `session.create`, naming the file, the key and
  # the fix. A session on a pod reads no gated key from the project's own file, whatever
  # the pod's user file says (Decision 686).
  defp config(workspace, opts) do
    trust = if Keyword.get(opts, :kind, :local) == :team, do: [trust: :never], else: []

    case Config.resolve(workspace.root_real, Keyword.get(opts, :config_overrides, []), trust) do
      {:ok, config, _layers} ->
        Config.log_warnings(config)
        {:ok, config}

      {:error, error} ->
        {:error, error}
    end
  end

  # A provider name nobody implements is a config mistake, and it used to be found by the
  # root agent, where `{:ok, adapter} = Provider.adapter(...)` crashed the tree on its way
  # up and the client was handed a supervisor shutdown blob. Answered here instead, before
  # anything starts, so `session.create` can say which name is wrong.
  defp known_provider(config) do
    case Provider.adapter(config.provider) do
      {:ok, _adapter} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Appended rather than merged: the plane's table never names the bundle, because the
  # plane does not know where a pod materialised it. A table that already has a
  # `skills` entry — a session restored with one — keeps it.

  # The agent names this session's team was granted, or `nil` for no restriction. A
  # local session and a laptop have no bundle and therefore no set, which is the same
  # answer by a shorter route.
  # `Workspace.new/1` refusing a directory that is not there is right, and it is the
  # wrong answer for one case: a session being resumed whose recorded directory has been
  # moved or deleted. Its history is intact and its tree is under the state directory
  # where a restore put it, and answering `not_a_directory` there loses a session over a
  # checkout somebody tidied up.
  #
  # Only a session that names itself, and only to a directory that already exists.
  # Nothing is created here: a session with neither its recorded workspace nor a restored
  # tree still fails, because putting an agent in a directory nobody asked for is the
  # thing `Workspace.new/1` is refusing to do.
  defp open_workspace(workspace_path, opts) do
    case Workspace.new(workspace_path) do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, {:not_a_directory, _path}} = error ->
        case restored_tree(opts) do
          nil -> error
          path -> Workspace.new(path)
        end

      error ->
        error
    end
  end

  defp restored_tree(opts) do
    with session_id when is_binary(session_id) <- Keyword.get(opts, :session_id),
         state_dir <- Keyword.get(opts, :config_overrides, [])[:state_dir],
         path <- Path.join([Troupe.Paths.state_dir(state_dir), "workspaces", session_id]),
         true <- File.dir?(path) do
      path
    else
      _ -> nil
    end
  end

  defp entitled_agents(%{entitlements: %{"agents" => names}}) when is_list(names), do: names
  defp entitled_agents(_bundle), do: nil

  # Narrowed before they become definitions, by the same set that narrows everything else.
  # An unnarrowed grant and a local session both record nothing, and nothing means every
  # one the bundle has — the same rule the other three kinds follow.
  defp acp_agents(%{acp_agents: entries} = bundle) when is_list(entries) do
    case get_in(bundle, [:entitlements, "acp_agents"]) do
      names when is_list(names) -> Enum.filter(entries, &(&1.name in names))
      _unnarrowed -> entries
    end
  end

  defp acp_agents(_bundle), do: []

  defp with_skills(%Mounts{} = mounts, bundle) do
    case {Skills.mount(bundle), Mounts.fetch(mounts, "skills")} do
      {nil, _} -> mounts
      {_entry, %Mounts.Entry{}} -> mounts
      {entry, nil} -> Mounts.new(mounts.entries ++ [entry])
    end
  end

  defp with_skills(mounts, _bundle), do: mounts

  @doc """
  A sortable, readable session id: a timestamp plus enough randomness to be unique.

  The shape is `Troupe.Protocol.SessionId`'s, because the plane hands out ids too.
  """
  @spec generate_id() :: String.t()
  defdelegate generate_id(), to: Troupe.Protocol.SessionId, as: :generate

  @doc """
  Whether a string has the shape `generate_id/0` gives it.

  A session id names a directory under the state root, and a dormant session is found by
  a glob built on it, so an id that comes from outside is held to this before anything
  looks for it (#97). Everything the harness generates passes, and a wildcard, a `..` or
  a separator cannot.
  """
  @spec valid_id?(term()) :: boolean()
  defdelegate valid_id?(id), to: Troupe.Protocol.SessionId, as: :valid?
end

defmodule Troupe.Sessions do
  @moduledoc """
  The DynamicSupervisor sessions live under.

  Sessions are `:transient`: one that finished normally must not be restarted, and one
  whose root Node exceeded its restart intensity is left down for `troupe resume`
  rather than looped.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl DynamicSupervisor
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    spec = %{
      id: {Troupe.Session, Keyword.fetch!(opts, :session_id)},
      start: {Troupe.Session, :start_link, [opts]},
      type: :supervisor,
      restart: :transient,
      shutdown: 30_000
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @spec stop_session(String.t()) :: :ok | {:error, :not_found}
  def stop_session(session_id) do
    case Troupe.Registry.whereis({:session, session_id}) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @spec list() :: [pid()]
  def list do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn {_, pid, _, _} -> if is_pid(pid), do: [pid], else: [] end)
  end
end
