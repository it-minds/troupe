defmodule Troupe do
  @moduledoc """
  Client API for tests and embedding.

      {:ok, sid} = Troupe.start_session(workspace: "/path", provider: {Troupe.LLM.Fake, fake})
      {:ok, path} = Troupe.dispatch(sid, "code", "fix the failing test")
      :ok = Troupe.subscribe(sid)
  """

  alias Troupe.Agent.Server
  alias Troupe.{Agents, Config, Paths, Session, Settings}
  alias Troupe.LLM.Provider
  alias Troupe.Session.{Approvals, Dispatcher, Log, Watcher}

  @type session_id :: String.t()

  @doc """
  Starts a session. Options: `:workspace` (default cwd), `:provider`
  (`{module, config}`), `:config` (map of `Troupe.Config` overrides),
  `:session_id` (to resume), `:auto_approve`, `:watch`.
  """
  @spec start_session(keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(opts \\ []) do
    workspace = opts |> Keyword.get(:workspace, File.cwd!()) |> Path.expand()
    overrides = opts |> Keyword.get(:config, %{}) |> Map.new()

    overrides =
      if Keyword.get(opts, :auto_approve),
        do: Map.put(overrides, :auto_approve, true),
        else: overrides

    overrides =
      if Keyword.has_key?(opts, :watch),
        do:
          Map.update(
            overrides,
            :watch,
            %{enabled: opts[:watch]},
            &Map.put(&1, :enabled, opts[:watch])
          ),
        else: overrides

    config = Config.load(workspace, overrides)
    definitions = Agents.load(workspace)
    provider = Keyword.get(opts, :provider) || default_provider(config)
    :ok = ensure_provider(provider, config)
    sid = Keyword.get(opts, :session_id) || Paths.new_session_id()

    session_opts = %{
      session_id: sid,
      workspace: workspace,
      config: config,
      definitions: definitions,
      provider: provider
    }

    case DynamicSupervisor.start_child(Troupe.Sessions, {Session, session_opts}) do
      {:ok, _pid} -> {:ok, sid}
      {:error, {:already_started, _}} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop_session(session_id()) :: :ok | {:error, :not_found}
  def stop_session(sid) do
    case Session.whereis(sid, :session) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(Troupe.Sessions, pid)
    end
  end

  @doc "Resumes a persisted session by id (searches every workspace's state dir)."
  @spec resume(session_id(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def resume(sid, opts \\ []) do
    case find_session(sid) do
      {:ok, workspace} -> start_session(Keyword.merge(opts, session_id: sid, workspace: workspace))
      :error -> {:error, :not_found}
    end
  end

  @doc "Lists persisted sessions as `%{session_id, workspace, path}`."
  @spec sessions(String.t() | nil) :: [map()]
  def sessions(workspace \\ nil) do
    {root, glob} =
      if workspace,
        do: {Paths.sessions_root(workspace), "*/meta.json"},
        else: {Path.join(Paths.state_dir(), "sessions"), "*/*/meta.json"}

    root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.flat_map(fn meta ->
      with {:ok, content} <- File.read(meta),
           {:ok, %{"session_id" => id, "workspace" => ws}} <- Jason.decode(content) do
        [%{session_id: id, workspace: ws, path: Path.dirname(meta)}]
      else
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.session_id, :desc)
  end

  @spec dispatch(session_id(), String.t(), String.t() | map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def dispatch(sid, name, args), do: Dispatcher.command(sid, name, args, :user)

  @doc "Sends user input to a branch; continues a finished branch."
  @spec send_input(session_id(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def send_input(sid, agent_path, text), do: Dispatcher.continue(sid, agent_path, text)

  @doc "Switches a branch's profile; works on finished branches too (applied when they continue)."
  @spec switch_profile(session_id(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def switch_profile(sid, agent_path, name), do: Dispatcher.switch_profile(sid, agent_path, name)

  @spec edit_todo(session_id(), String.t(), {:cancel, String.t()} | {:add, String.t()}) ::
          :ok | {:error, :not_running}
  def edit_todo(sid, agent_path, change),
    do: send_agent(sid, agent_path, {:input, :tui_todo_edit, change})

  @spec cancel(session_id(), String.t()) :: :ok | {:error, :not_running}
  def cancel(sid, agent_path), do: send_agent(sid, agent_path, :cancel)

  @spec dismiss(session_id(), String.t()) :: :ok | {:error, String.t()}
  def dismiss(sid, agent_path), do: Dispatcher.dismiss(sid, agent_path)

  @spec subscribe(session_id()) :: :ok
  def subscribe(sid), do: Troupe.Events.subscribe(sid)

  @spec approve(session_id(), String.t(), :allow | :deny | :allow_session) ::
          :ok | {:error, :unknown_call}
  def approve(sid, call_id, decision), do: Approvals.answer(sid, call_id, decision)

  @spec answer(session_id(), String.t(), String.t()) :: :ok | {:error, :unknown_call}
  def answer(sid, call_id, text), do: Approvals.answer(sid, call_id, {:text, text})

  @spec merge(session_id(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def merge(sid, agent_path), do: Dispatcher.merge(sid, agent_path)

  @spec discard(session_id(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def discard(sid, agent_path), do: Dispatcher.discard(sid, agent_path)

  @spec windows(session_id()) :: [Dispatcher.window()]
  def windows(sid), do: Dispatcher.windows(sid)

  @spec events(session_id()) :: [Troupe.Event.t()]
  def events(sid), do: Log.all(sid)

  @doc "The session's live config and its workspace."
  @spec config(session_id()) :: {String.t(), Config.t()}
  def config(sid), do: Dispatcher.context(sid)

  @doc """
  Changes one `Troupe.Settings` key: applies it to the running session and
  writes it to the config file that owns it. Settings whose effect is
  `:new_branches` reach branches dispatched from now on, not running ones.

  Returns the updated config with the file written to, or `{:error, message}`
  when the value was applied to the session but could not be persisted.
  """
  @spec put_setting(session_id(), String.t(), term()) ::
          {:ok, Config.t(), String.t()} | {:error, String.t()}
  def put_setting(sid, key, value) do
    case Settings.fetch(key) do
      :error ->
        {:error, "unknown setting #{key}"}

      {:ok, _field} ->
        {workspace, cfg} = Dispatcher.context(sid)
        updated = Settings.put(cfg, key, value)
        :ok = Dispatcher.put_config(sid, updated)
        :ok = apply_live(sid, key, updated)

        case Settings.persist(workspace, key, value) do
          {:ok, path} -> {:ok, updated, path}
          {:error, msg} -> {:error, "applied to this session only: " <> msg}
        end
    end
  end

  defp apply_live(sid, "auto_approve", cfg), do: Approvals.set_auto_approve(sid, cfg.auto_approve)

  defp apply_live(sid, "watch.enabled", cfg) do
    :ok = Watcher.put_config(sid, cfg)

    if cfg.watch.enabled do
      {:ok, _backend} = Watcher.enable(sid)
      :ok
    else
      Watcher.disable(sid)
    end
  end

  defp apply_live(sid, "watch." <> _, cfg), do: Watcher.put_config(sid, cfg)
  defp apply_live(_sid, _key, _cfg), do: :ok

  @spec watch(session_id(), boolean()) :: {:ok, atom()} | :ok
  def watch(sid, true), do: Watcher.enable(sid)
  def watch(sid, false), do: Watcher.disable(sid)

  @spec agent_pid(session_id(), String.t()) :: pid() | nil
  def agent_pid(sid, agent_path), do: Server.whereis(sid, agent_path)

  defp send_agent(sid, agent_path, msg) do
    case Server.whereis(sid, agent_path) do
      nil ->
        {:error, :not_running}

      pid ->
        send(pid, msg)
        :ok
    end
  end

  defp find_session(sid) do
    case Enum.find(sessions(), &(&1.session_id == sid)) do
      %{workspace: ws} -> {:ok, ws}
      nil -> :error
    end
  end

  # Named providers are picked per request from the model's `provider/` prefix (:auto);
  # a single session-wide provider is fixed up front.
  defp default_provider(%Config{providers: providers} = config)
       when map_size(providers) > 0 and config.provider != :fake, do: :auto

  defp default_provider(config), do: Provider.from_config(config)

  # The release-mode Fake (TROUPE_PROVIDER=fake) is a named process started on demand.
  defp ensure_provider({Troupe.LLM.Fake, Troupe.LLM.Fake}, config) do
    if Process.whereis(Troupe.LLM.Fake) do
      :ok
    else
      script = if config.fake_script, do: Troupe.LLM.Fake.load_script(config.fake_script), else: []

      case DynamicSupervisor.start_child(
             Troupe.Providers,
             {Troupe.LLM.Fake, [name: Troupe.LLM.Fake, script: script]}
           ) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end
  end

  defp ensure_provider(_provider, _config), do: :ok
end
