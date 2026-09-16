defmodule Troupe.Client.Local do
  @moduledoc """
  `Troupe.Client` over the in-process session API: the behaviour the harness
  already had, given the shape the remote one also has.

  Everything here is a thin wrapper on purpose. The only real work is where the
  remote vocabulary and the local one differ — a local session is `:active`
  while it runs and `:dormant` once it is only on disk, its scopes are always
  `observe` and `control`, and `teams` is empty because a local machine has no
  fleet.
  """

  @behaviour Troupe.Client

  alias Troupe.{Agents, Events, Session}
  alias Troupe.Session.{Dispatcher, Index, Log, Memory, Watcher, Worktree}

  @scopes ["observe", "control"]

  ## Session-scoped

  @impl true
  def subscribe(sid), do: Events.subscribe(sid)

  @impl true
  def unsubscribe(sid), do: Events.unsubscribe(sid)

  @impl true
  def events(sid), do: Log.all(sid)

  @impl true
  def commands(sid), do: Dispatcher.commands(sid)

  @impl true
  def context(sid), do: Dispatcher.context(sid)

  @impl true
  def capability(sid) do
    running? = Session.whereis(sid, :dispatcher) != nil

    %{
      state: if(running?, do: :active, else: :dormant),
      scopes: @scopes,
      can_input?: running?,
      can_approve?: running?,
      reason: if(running?, do: nil, else: "this session is not running"),
      up?: true,
      remote?: false
    }
  end

  @impl true
  def dispatch(sid, name, args), do: Troupe.dispatch(sid, name, args)

  @impl true
  def send_input(sid, path, text), do: Troupe.send_input(sid, path, text)

  @impl true
  def approve(sid, call_id, decision), do: Troupe.approve(sid, call_id, decision)

  @impl true
  def answer(sid, call_id, text), do: Troupe.answer(sid, call_id, text)

  @impl true
  def edit_todo(sid, path, change), do: Troupe.edit_todo(sid, path, change)

  @impl true
  def switch_profile(sid, path, name), do: Troupe.switch_profile(sid, path, name)

  @impl true
  def cancel_branch(sid, path), do: Troupe.cancel_branch(sid, path)

  @impl true
  def dismiss(sid, path), do: Troupe.dismiss(sid, path)

  @impl true
  def merge(sid, path), do: Troupe.merge(sid, path)

  @impl true
  def discard(sid, path), do: Troupe.discard(sid, path)

  @impl true
  def put_setting(sid, key, value), do: Troupe.put_setting(sid, key, value)

  @impl true
  def watch(sid, enabled?), do: Troupe.watch(sid, enabled?)

  @impl true
  def watch_status(sid), do: Watcher.status(sid)

  @impl true
  def memory(sid, "refresh") do
    case Troupe.dispatch(
           sid,
           "librarian",
           "The project brief is out of date. Revise it against the repository as it is now."
         ) do
      {:ok, _path} -> {:ok, "refreshing the project brief"}
      {:error, reason} -> {:error, reason}
    end
  end

  def memory(sid, "forget") do
    :ok = Memory.forget(sid)
    {:ok, "project brief forgotten; /memory refresh writes a new one"}
  end

  def memory(sid, "") do
    case Memory.brief(sid) do
      nil ->
        {:ok, "no project brief yet; /memory refresh writes one"}

      brief ->
        titles = brief.sections |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 == ""))
        built = if brief.built_at, do: DateTime.to_date(brief.built_at), else: "never"

        {:ok, "project brief (#{Memory.status(sid)}, built #{built}): " <> Enum.join(titles, ", ")}
    end
  end

  def memory(_sid, other),
    do: {:error, "unknown /memory #{other}; use /memory, /memory refresh or /memory forget"}

  # The files panel works on a local session too: the mount names match the
  # remote ones so the panel itself has no idea which side it is showing.
  @impl true
  def fs_list(sid, path) do
    with {:ok, absolute, workspace} <- resolve(sid, path) do
      case File.ls(absolute) do
        {:ok, names} ->
          {:ok,
           names
           |> Enum.sort()
           |> Enum.map(fn name ->
             full = Path.join(absolute, name)

             %{
               name: name,
               path: Path.join(strip_mount(path), name),
               dir?: File.dir?(full),
               size: size(full),
               workspace: workspace
             }
           end)}

        {:error, reason} ->
          {:error, :file.format_error(reason) |> to_string()}
      end
    end
  end

  @impl true
  def fs_read(sid, path) do
    with {:ok, absolute, _workspace} <- resolve(sid, path) do
      case File.read(absolute) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, to_string(:file.format_error(reason))}
      end
    end
  end

  @impl true
  def fs_upload(sid, path, content) do
    with {:ok, absolute, _workspace} <- resolve(sid, path) do
      File.mkdir_p!(Path.dirname(absolute))

      case File.write(absolute, content) do
        :ok -> :ok
        {:error, reason} -> {:error, to_string(:file.format_error(reason))}
      end
    end
  end

  @impl true
  def stop_session(sid), do: Troupe.stop_session(sid)

  @impl true
  def has_session?(sid), do: Session.whereis(sid, :session) != nil

  @impl true
  def idle?(sid), do: Session.whereis(sid, :dispatcher) != nil and Dispatcher.windows(sid) == []

  ## Fleet-scoped

  @impl true
  def teams(_origin), do: {:ok, []}

  @impl true
  def profiles({:local, workspace}, _team) do
    profiles =
      workspace
      |> Agents.load()
      |> Agents.primaries()
      |> Enum.map(
        &%{
          name: &1.name,
          description: &1.description,
          health: "local",
          capacity: %{free: nil, total: nil}
        }
      )

    {:ok, profiles}
  end

  def profiles(_origin, _team), do: {:ok, []}

  @impl true
  def sessions({:local, workspace}, _filter) do
    {:ok, Enum.map(Index.list(workspace), &summary(&1, workspace))}
  end

  def sessions(_origin, _filter), do: {:ok, []}

  @impl true
  def create_session({:local, workspace}, params) do
    with {:ok, sid} <- Troupe.start_session(workspace: workspace),
         {:ok, _path} <- dispatch_prompt(sid, params) do
      {:ok, sid}
    end
  end

  def create_session(_origin, _params), do: {:error, :unsupported}

  # `like:` is the session the user is switching away from: the one on screen
  # keeps its resolved provider and any setting flipped this run, rather than
  # the session coming up with a fresh read of the config files.
  @impl true
  def open_session({:local, workspace}, sid, _mode, opts) do
    cond do
      has_session?(sid) -> {:ok, sid}
      Keyword.get(opts, :like) -> resume_like(sid, workspace, Keyword.fetch!(opts, :like))
      true -> Troupe.resume(sid)
    end
  end

  def open_session(_origin, _sid, _mode, _opts), do: {:error, :unsupported}

  defp resume_like(sid, workspace, like) do
    if Session.whereis(like, :dispatcher) do
      {_workspace, config} = Dispatcher.context(like)

      Troupe.start_session(
        session_id: sid,
        workspace: workspace,
        provider: Dispatcher.provider(like),
        config: Map.from_struct(config)
      )
    else
      Troupe.resume(sid)
    end
  end

  @impl true
  def whoami({:local, workspace}) do
    {:ok,
     %{
       sub: System.get_env("USER") || System.get_env("USERNAME") || "local",
       name: "local",
       teams: [],
       plane_url: nil,
       workspace: workspace
     }}
  end

  def whoami(_origin), do: {:error, :unsupported}

  @impl true
  def fleet_status({:local, workspace}),
    do: %{up?: true, origin: {:local, workspace}, principal: nil, scopes: @scopes, error: nil}

  def fleet_status(origin),
    do: %{up?: false, origin: origin, principal: nil, scopes: [], error: :unsupported}

  @impl true
  def subscribe_fleet(_origin), do: :ok

  ## Helpers the UI needs and cannot reach itself

  @doc "The worktrees this workspace has, and the ones Troupe manages for it."
  @spec worktrees(String.t()) :: {[map()], [String.t()]}
  def worktrees(workspace), do: {Worktree.list(workspace), Worktree.managed(workspace)}

  @doc "The text a multiple-choice answer is sent as."
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels), do: Troupe.Tools.AskUser.answer_text(labels)

  ## Internals

  defp dispatch_prompt(sid, %{prompt: prompt} = params) when is_binary(prompt) and prompt != "" do
    profile = Map.get(params, :profile) || "code"
    Troupe.dispatch(sid, profile, prompt)
  end

  defp dispatch_prompt(sid, _params), do: {:ok, sid}

  defp summary(entry, workspace) do
    %{
      id: entry.session_id,
      title: entry.title,
      owner: nil,
      team: nil,
      profile: entry.branches |> List.first() |> then(&(&1 && &1.name)),
      state: if(entry.running?, do: :active, else: :dormant),
      status: status_text(entry),
      tokens: nil,
      cost: nil,
      updated_at: entry.updated_at,
      origin: {:local, entry.workspace || workspace},
      branches: entry.branches,
      workspace: entry.workspace
    }
  end

  defp status_text(entry) do
    case Index.live_branches(entry) do
      [] -> "no branches"
      branches -> "#{length(branches)} branch(es)"
    end
  end

  # Mounts: `session:/…` is the session's workspace. A local session has no
  # `team:` mount, and a path that names one is refused rather than silently
  # resolved against the workspace.
  defp resolve(sid, path) do
    {workspace, _config} = Dispatcher.context(sid)
    relative = strip_mount(path)

    cond do
      String.starts_with?(path, "team:") ->
        {:error, "local sessions have no team mount"}

      String.contains?(relative, "..") ->
        {:error, "path escapes the workspace"}

      true ->
        {:ok, Path.join(workspace, relative), workspace}
    end
  end

  defp strip_mount("session:/" <> rest), do: rest
  defp strip_mount("session:" <> rest), do: String.trim_leading(rest, "/")
  defp strip_mount(path), do: String.trim_leading(path, "/")

  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end
end
