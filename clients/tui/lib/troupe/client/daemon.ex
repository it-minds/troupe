defmodule Troupe.Client.Daemon do
  @moduledoc """
  `Troupe.Client` over the local daemon.

  A session on this machine runs in `troupe-daemon` — or in the daemon this process
  embeds when none answers (`Troupe.Client.Daemon.Link`) — and the TUI reaches it the way
  it reaches a worker pod: the daemon's loopback WebSocket, one `Troupe.Remote.Worker`
  per attached session, the same `Troupe.Remote.Translate` at the edge. Nothing here
  calls the harness in-process; if the TUI can do something, any protocol client can.

  Fleet-level calls — listing, creating and opening sessions, the agents a workspace
  offers, its worktrees — go through the link's own connection to the daemon.

  A **branch** — `/build fix the test` typed on this session's screen — is a session of
  its own in the daemon (decision 7.3 b), created with `parent` set to this one and in
  its own worktree when the checkout is busy, and shown here as a window named the way a
  local branch always was: `build-1`. Its worker publishes under that name
  (`Troupe.Remote.Branch`), its events are read back beside this session's, input typed
  into the window goes to it, an approval it asks is answered through it, and `/merge`
  and `/discard` end its worktree through `worktree.merge` and `worktree.discard`. The
  parent's journal remembers which windows exist (`branch_spawned` with the branch's
  session id, `window_dismissed`), which is what re-opens them with the session.

  The **project brief** (`.troupe/memory.md`, troupe-remote Decision 649) is the
  daemon's: it reads it into every prompt and `remember` writes it. What is the client's
  is `/memory` — showing it, forgetting it, and asking the `librarian` to write it — and
  the refresh a session starts with when the brief is missing or stale and the workspace
  config asks for one (`memory_auto_refresh`): a `librarian` branch in the checkout
  itself, since all it writes is the brief.

  What a daemon session does not have yet says so in words: the settings that changed a
  running agent (phase 3 of the daemon plan).
  """

  @behaviour Troupe.Client

  alias Troupe.Client.Daemon.Link
  alias Troupe.Client.Events
  alias Troupe.{Config, Settings}
  alias Troupe.Remote.{Branch, Capability, Journal, Worker}

  @scopes ["observe", "control", "admin"]
  @refresh_prompt "The project brief is out of date. Revise it against the repository as it is now."
  @first_prompt "There is no project brief yet. Survey this repository and write one."
  # The journal keys its directory by where the session lives; a daemon session lives here.
  @journal_key "daemon"

  ## Session-scoped

  @impl true
  def subscribe(sid), do: Events.subscribe(sid)

  @impl true
  def unsubscribe(sid), do: Events.unsubscribe(sid)

  # This session's transcript and its branches', the latter under their window names,
  # in the order they happened.
  @impl true
  def events(sid) do
    branches =
      Enum.flat_map(branches(sid), fn branch ->
        branch.session_id
        |> Journal.all()
        # This journal's own `branch_spawned` opened the window, with the right name.
        |> Enum.reject(&(&1.type == :branch_spawned))
        |> Enum.map(fn event ->
          %{event | session_id: sid, agent_path: Branch.rewrite(event.agent_path, branch.window)}
        end)
      end)

    Enum.sort_by(Journal.all(sid) ++ branches, & &1.ts)
  end

  # The agents a slash command may start a branch on, plus `/worktree`: the default
  # agent, always in a worktree of its own.
  @impl true
  def commands(sid) do
    case profiles({:local, workspace(sid)}, nil) do
      {:ok, profiles} -> Enum.map(profiles, & &1.name) ++ ["worktree"]
      _ -> ["worktree"]
    end
  end

  @impl true
  def context(sid) do
    workspace = workspace(sid)
    {workspace, Config.load(workspace)}
  end

  @impl true
  def capability(sid) do
    case Worker.whereis(sid) do
      nil ->
        %{
          state: :dormant,
          scopes: @scopes,
          can_input?: false,
          can_approve?: false,
          reason: "this session is not open",
          up?: Link.up?(),
          remote?: false
        }

      _pid ->
        status = Worker.status(sid)
        %{Capability.of(status.state, status.scopes, status.up?) | remote?: false}
    end
  end

  # `/build fix the test` starts a branch: a session of its own in this workspace
  # (decision 7.3 b), with `parent` set to this one and its own worktree when the
  # checkout is busy — which it is, since this session works in it — shown here as the
  # window `build-1`. `/worktree …` is the default agent, always in a worktree.
  @impl true
  def dispatch(sid, name, args) do
    with {:ok, profile, mode, kind} <- branch_profile(sid, name),
         {workflow, prompt} = workflow_and_prompt(sid, kind, prompt_of(args)),
         window = Branch.next_name(window_names(sid), name),
         {:ok, child} <- create_branch(sid, profile, prompt, mode, workflow),
         {:ok, _} <- open_branch(sid, child, window, profile, prompt) do
      {:ok, window}
    end
  end

  @impl true
  def send_input(sid, path, text), do: route(sid, path, &Worker.input(&1, text))

  @impl true
  def approve(sid, call_id, decision),
    do: describe(Worker.approve(call_target(sid, call_id), call_id, decision))

  @impl true
  def answer(sid, call_id, text),
    do: describe(Worker.answer(call_target(sid, call_id), call_id, text))

  @impl true
  def edit_todo(sid, path, change), do: route(sid, path, &Worker.edit_todo(&1, change))

  @impl true
  def switch_profile(sid, path, name), do: route(sid, path, &Worker.switch_profile(&1, name))

  # The session's goal is the daemon's: the root agent writes it as an event and reads it
  # into every later prompt, so this only asks, and the window hears the event.
  @impl true
  def goal(sid) do
    case Worker.goal(sid) do
      {:ok, %{"goal" => goal}} -> {:ok, goal}
      {:ok, other} -> {:error, "unexpected session.goal.get answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def set_goal(sid, text), do: describe(Worker.set_goal(sid, text))

  @impl true
  def clear_goal(sid), do: describe(Worker.set_goal(sid, nil))

  # A loop is the harness's too (`session.loop.*`): this asks, and the window follows the
  # session's own `loop_*` events.
  @impl true
  def loop(sid) do
    case Worker.loop(sid) do
      {:ok, %{"loop" => loop}} -> {:ok, loop}
      {:ok, other} -> {:error, "unexpected session.loop.get answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def start_loop(sid, n), do: describe(Worker.start_loop(sid, n))

  @impl true
  def stop_loop(sid), do: describe(Worker.stop_loop(sid))

  @impl true
  def cancel_branch(sid, path), do: route(sid, path, &Worker.cancel/1)

  @impl true
  def compact(_sid, _path), do: {:error, "the daemon compacts a session on its own"}

  # Dismissing this session's own window lets go of the session; dismissing a branch's
  # closes the window for good and leaves the session to the daemon, where the picker
  # still lists it.
  @impl true
  def dismiss(sid, path) do
    case branch(sid, path) do
      nil ->
        Worker.detach(sid)
        :ok

      branch ->
        close_branch(sid, branch)
        :ok
    end
  end

  @impl true
  def merge(sid, path) do
    with {:ok, branch} <- worktree_branch(sid, path) do
      params = %{
        workspace: workspace(sid),
        path: branch.worktree,
        message: "troupe(#{branch.window}): #{first_line(branch.prompt)}",
        command_id: Troupe.Remote.RPC.command_id()
      }

      case Link.call("worktree.merge", params) do
        {:ok, %{} = result} ->
          record(sid, branch.window, :worktree_merged, %{
            output: result["output"] || "",
            conflicts: false
          })

          close_branch(sid, branch)
          {:ok, "merged #{branch.git_branch} into the checkout"}

        {:error, "conflict" <> _ = reason} ->
          record(sid, branch.window, :worktree_merged, %{output: reason, conflicts: true})
          {:error, "merge conflicts; resolve in your checkout: #{reason}"}

        {:error, reason} ->
          {:error, message(reason)}
      end
    end
  end

  @impl true
  def discard(sid, path) do
    with {:ok, branch} <- worktree_branch(sid, path) do
      params = %{
        workspace: workspace(sid),
        path: branch.worktree,
        command_id: Troupe.Remote.RPC.command_id()
      }

      case Link.call("worktree.discard", params) do
        {:ok, _} ->
          record(sid, branch.window, :worktree_discarded, %{})
          close_branch(sid, branch)
          {:ok, "discarded #{branch.git_branch}"}

        {:error, reason} ->
          {:error, message(reason)}
      end
    end
  end

  # Settings live in the config files the daemon reads at session start. `watch` is the
  # one a running session can take, through the protocol.
  @impl true
  def put_setting(sid, key, value) do
    workspace = workspace(sid)

    with {:ok, path} <- Settings.persist(workspace, key, value),
         :ok <- apply_live(sid, key, value) do
      {:ok, Config.load(workspace), path}
    end
  end

  defp apply_live(sid, "watch", enabled?) when is_boolean(enabled?) do
    case watch(sid, enabled?) do
      {:ok, _backend} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_live(_sid, _key, _value), do: :ok

  @impl true
  def watch(sid, enabled?) do
    case Worker.whereis(sid) do
      nil ->
        {:error, "this session is not open"}

      _pid ->
        case Worker.rpc(sid, "watch.set", %{workspace: workspace(sid), enabled: enabled?}) do
          {:ok, %{"backend" => backend}} when is_binary(backend) ->
            Link.put_watch(sid, enabled?, backend)
            {:ok, String.to_atom(backend)}

          {:ok, _} ->
            Link.put_watch(sid, enabled?, nil)
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def watch_status(sid), do: Link.watch_status(sid)

  # The workspace's own MCP servers (troupe-remote Decision 654), as the `/mcp` page
  # draws them: a count of tools, and the error when there is one.
  @impl true
  def mcp_status(sid) do
    case Worker.rpc(sid, "mcp.status", %{}) do
      {:ok, %{"servers" => servers}} when is_list(servers) ->
        Enum.map(servers, fn server ->
          %{
            name: server["name"],
            state: mcp_state(server["state"]),
            tools: server["tools"] |> List.wrap() |> length(),
            error: server["error"]
          }
        end)

      _ ->
        []
    end
  end

  defp mcp_state("ready"), do: :ready
  defp mcp_state("connecting"), do: :connecting
  defp mcp_state("error"), do: :error
  defp mcp_state("stopped"), do: :stopped
  defp mcp_state(_other), do: :unknown

  # `/memory` shows the brief, `/memory refresh` has the librarian rewrite it as a branch
  # of this session, `/memory forget` deletes it.
  @impl true
  def memory(sid, "") do
    case Link.call("memory.get", %{workspace: workspace(sid)}) do
      {:ok, %{"status" => "absent"}} ->
        {:ok, "no project brief yet; /memory refresh writes one"}

      {:ok, %{"status" => "disabled"}} ->
        {:ok, "the project brief is off (memory: false in the workspace config)"}

      {:ok, %{"status" => status} = brief} ->
        built = if brief["built_at"], do: String.slice(brief["built_at"], 0, 10), else: "never"
        sections = Enum.join(brief["sections"] || [], ", ")
        {:ok, "project brief (#{status}, built #{built}): #{sections}"}

      {:ok, other} ->
        {:error, "unexpected memory.get answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def memory(sid, "refresh") do
    case dispatch(sid, "librarian", @refresh_prompt) do
      {:ok, window} -> {:ok, "refreshing the project brief in #{window}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def memory(sid, "forget") do
    params = %{workspace: workspace(sid), command_id: Troupe.Remote.RPC.command_id()}

    case Link.call("memory.forget", params) do
      {:ok, _} -> {:ok, "project brief forgotten; /memory refresh writes a new one"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def memory(_sid, other),
    do: {:error, "unknown /memory #{other}; use /memory, /memory refresh or /memory forget"}

  @impl true
  def fs_list(sid, path) do
    case Worker.fs_list(sid, path) do
      {:ok, %{"entries" => entries}} -> {:ok, Enum.map(entries, &entry/1)}
      {:ok, other} -> {:error, "unexpected fs.list answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_read(sid, path) do
    case Worker.fs_read(sid, path) do
      {:ok, %{"content" => content}} -> {:ok, content}
      {:ok, %{"content_base64" => b64}} -> {:ok, Base.decode64!(b64)}
      {:ok, other} -> {:error, "unexpected fs.read answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_upload(sid, path, content), do: describe(Worker.fs_upload(sid, path, content))

  # Stopping means letting go: the daemon keeps the session and idles it on its own.
  # Its branches' windows go with the screen they were on.
  @impl true
  def stop_session(sid) do
    for branch <- branches(sid), do: Worker.detach(branch.session_id)
    Worker.detach(sid)
    :ok
  end

  @impl true
  def has_session?(sid), do: Worker.whereis(sid) != nil

  # The scratch session `troupe` opens is idle until somebody has typed into it.
  @impl true
  def idle?(sid) do
    has_session?(sid) and not Enum.any?(Journal.all(sid), &(&1.type in [:input, :user_input]))
  end

  ## Fleet-scoped

  @impl true
  def teams(_origin), do: {:ok, []}

  @impl true
  def profiles({:local, workspace}, _team) do
    case Link.call("agents.list", %{workspace: workspace}) do
      {:ok, %{"agents" => agents}} ->
        {:ok,
         Enum.map(agents, fn agent ->
           %{
             name: agent["name"],
             description: agent["description"] || "",
             health: "local",
             capacity: %{free: nil, total: nil}
           }
         end)}

      {:ok, other} ->
        {:error, "unexpected agents.list answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def profiles(_origin, _team), do: {:ok, []}

  @impl true
  def sessions({:local, workspace} = origin, _filter) do
    case Link.call("session.list", %{filter: %{workspace: workspace}}) do
      {:ok, %{"sessions" => sessions}} ->
        rows =
          sessions
          |> Enum.map(&summary(&1, origin))
          |> Enum.sort_by(&(&1.updated_at || 0), :desc)

        {:ok, rows}

      {:ok, other} ->
        {:error, "unexpected session.list answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def sessions(_origin, _filter), do: {:ok, []}

  @doc """
  Create a session in a workspace and attach to it.

  `params`: `profile`, `prompt`, `worktree` (`"auto"`, `"never"`, `"always"`), and a
  `config` map of what a client may set — `auto_approve`, `watch`.
  """
  @impl true
  def create_session({:local, workspace} = origin, params) do
    body =
      %{
        workspace: workspace,
        profile: params[:profile],
        prompt: blank_to_nil(params[:prompt]),
        worktree: params[:worktree] || "never",
        config: params[:config] || %{},
        command_id: Troupe.Remote.RPC.command_id()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Link.call("session.create", body) do
      {:ok, %{"session_id" => sid} = result} ->
        with {:ok, ^sid} <-
               attach(origin, sid, %{
                 workspace: result["workspace"] || workspace,
                 profile: params[:profile],
                 title: params[:prompt]
               }) do
          refresh_brief_if_asked(sid, result["workspace"] || workspace)
          {:ok, sid}
        end

      {:ok, other} ->
        {:error, "unexpected session.create answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def create_session(_origin, _params), do: {:error, :unsupported}

  # Opening never wakes a dormant session; the first activating command does, in the
  # daemon. So `mode` has nothing to decide here.
  @impl true
  def open_session({:local, workspace} = origin, sid, _mode, _opts) do
    if has_session?(sid) do
      {:ok, sid}
    else
      case Link.call("session.get", %{session_id: sid}) do
        {:ok, %{} = row} ->
          with {:ok, ^sid} <-
                 attach(origin, sid, %{
                   workspace: row["workspace"] || workspace,
                   profile: row["profile"],
                   title: row["title"]
                 }) do
            reopen_branches(sid)
            {:ok, sid}
          end

        {:error, reason} ->
          {:error, message(reason)}
      end
    end
  end

  def open_session(_origin, _sid, _mode, _opts), do: {:error, :unsupported}

  @impl true
  def whoami({:local, workspace}) do
    identity =
      case Link.call("identity.get", %{}) do
        {:ok, %{} = identity} -> identity
        _ -> %{}
      end

    {:ok,
     %{
       sub:
         identity["subject"] ||
           "local:" <> (System.get_env("USER") || System.get_env("USERNAME") || "local"),
       name: identity["display_name"] || "local",
       teams: [],
       plane_url: identity["plane_url"],
       workspace: workspace
     }}
  end

  def whoami(_origin), do: {:error, :unsupported}

  @impl true
  def fleet_status({:local, workspace}) do
    %{
      up?: Link.up?(),
      origin: {:local, workspace},
      principal: nil,
      scopes: @scopes,
      error: Link.error()
    }
  end

  def fleet_status(origin),
    do: %{up?: false, origin: origin, principal: nil, scopes: [], error: :unsupported}

  @impl true
  def subscribe_fleet(_origin), do: :ok

  ## Helpers the UI needs and cannot reach itself

  @doc "The worktrees this workspace has. The daemon manages them; none are the TUI's own."
  @spec worktrees(String.t()) :: {[map()], [String.t()]}
  def worktrees(workspace) do
    case Link.call("worktree.list", %{workspace: workspace}) do
      {:ok, %{"worktrees" => list}} ->
        {Enum.map(
           list,
           &%{rel: Path.basename(&1["path"] || ""), path: &1["path"], branch: &1["branch"]}
         ), []}

      _ ->
        {[], []}
    end
  end

  @doc "The text a multiple-choice answer is sent as."
  @spec answer_text([String.t()]) :: String.t()
  def answer_text(labels), do: Enum.join(labels, ", ")

  ## Attaching

  # One worker connection per attached session, over the daemon's loopback WebSocket
  # with the daemon's own token: a daemon session is reached exactly as a pod's is, with
  # no plane in the way.
  defp attach(_origin, sid, meta) do
    with {:ok, ws} <- Link.websocket(),
         {:ok, _journal} <-
           start_child({Journal, [session_id: sid, plane_url: @journal_key, title: meta[:title]]}),
         {:ok, _worker} <-
           start_child(
             {Worker,
              [
                session_id: sid,
                plane_url: nil,
                endpoint: "ws://127.0.0.1:#{ws.port}/v1/socket",
                token: ws.token,
                impl: __MODULE__,
                state: :active,
                workspace: meta[:workspace],
                profile: meta[:profile],
                title: meta[:title],
                as: meta[:as]
              ]}
           ) do
      {:ok, sid}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  ## Branches

  # What this session's journal says its windows are: every branch opened here and not
  # dismissed, with the session it is. The journal is the record because the daemon's
  # listing knows the parent of a session but not what its parent's screen called it.
  defp branches(sid) do
    sid
    |> Journal.all()
    |> Enum.reduce(%{}, fn
      %{type: :branch_spawned, agent_path: window, data: %{session_id: child} = data}, acc
      when is_binary(child) ->
        Map.put(acc, window, %{
          window: window,
          session_id: child,
          profile: data[:name],
          prompt: data[:prompt] || "",
          worktree: data[:worktree],
          git_branch: data[:git_branch]
        })

      %{type: :window_dismissed, agent_path: window}, acc ->
        Map.delete(acc, window)

      _event, acc ->
        acc
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.window)
  end

  # Every window name this session ever had, dismissed ones included, so a name is not
  # given twice.
  defp window_names(sid) do
    sid
    |> Journal.all()
    |> Enum.filter(&(&1.type == :branch_spawned))
    |> Enum.map(& &1.agent_path)
    |> Enum.uniq()
  end

  defp branch(sid, path) when is_binary(path) do
    window = Branch.window_of(path)
    Enum.find(branches(sid), &(&1.window == window))
  end

  defp branch(_sid, _path), do: nil

  defp route(sid, path, fun) do
    case {path, branch(sid, path)} do
      {_, %{session_id: child}} -> describe(fun.(child))
      {path, nil} when path in [nil, "root", "session", "session-1"] -> describe(fun.(sid))
      {path, nil} -> {:error, "no window #{path}"}
    end
  end

  # An approval asked by a branch was registered under this session and its call id by
  # the branch's worker; anything else is this session's own.
  defp call_target(sid, call_id) do
    case Registry.lookup(Troupe.Client.Registry, {:call, sid, call_id}) do
      [{_pid, child}] -> child
      [] -> sid
    end
  end

  defp branch_profile(sid, "worktree"),
    do: {:ok, Config.load(workspace(sid)).default_agent, "always", :agent}

  # The librarian writes one file, the brief at the repository's root; it works in the
  # checkout itself rather than a worktree it would have to be merged out of.
  defp branch_profile(_sid, "librarian"), do: {:ok, "librarian", "never", :agent}

  # A workflow's subagents write, so it always gets a worktree of its own; the daemon
  # renders the plan (troupe-remote Decision 648).
  defp branch_profile(_sid, "workflow"), do: {:ok, "workflow", "always", :workflow}

  defp branch_profile(sid, name) do
    primaries =
      case profiles({:local, workspace(sid)}, nil) do
        {:ok, profiles} -> Enum.map(profiles, & &1.name)
        _ -> []
      end

    if name in primaries do
      {:ok, name, "auto", :agent}
    else
      {:error,
       "unknown command /#{name}; available: " <>
         Enum.map_join(Enum.uniq(primaries ++ ["worktree"]), ", ", &("/" <> &1))}
    end
  end

  # `/workflow release: cut 1.2` names the workflow; so does a leading word that is one
  # of the workspace's (`/workflow release cut 1.2`); anything else is the default
  # pipeline with the whole line as the task.
  defp workflow_and_prompt(_sid, :agent, prompt), do: {nil, prompt}

  defp workflow_and_prompt(sid, :workflow, prompt) do
    names =
      case Link.call("workflows.list", %{workspace: workspace(sid)}) do
        {:ok, %{"workflows" => names}} when is_list(names) -> names
        _ -> ["default"]
      end

    case String.split(prompt, ~r/\s+/, parts: 2) do
      [word, rest] when word != "" ->
        cond do
          String.ends_with?(word, ":") -> {String.trim_trailing(word, ":"), String.trim(rest)}
          word in names -> {word, String.trim(rest)}
          true -> {"default", prompt}
        end

      _ ->
        {"default", prompt}
    end
  end

  defp prompt_of(args) when is_binary(args), do: String.trim(args)
  defp prompt_of(%{} = args), do: prompt_of(args[:prompt] || args["prompt"] || "")
  defp prompt_of(_args), do: ""

  defp create_branch(sid, profile, prompt, mode, workflow) do
    body =
      %{
        workspace: workspace(sid),
        profile: profile,
        prompt: blank_to_nil(prompt),
        worktree: mode,
        parent: sid,
        workflow: workflow,
        config: %{},
        command_id: Troupe.Remote.RPC.command_id()
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Link.call("session.create", body) do
      {:ok, %{"session_id" => child} = result} ->
        {:ok,
         %{
           id: child,
           workspace: result["workspace"] || workspace(sid),
           worktree: result["worktree"],
           git_branch: result["branch"]
         }}

      {:ok, other} ->
        {:error, "unexpected session.create answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  # The window opens in this session's journal — `branch_spawned` carrying the branch's
  # session id, then `worktree_created` when it has one — and the branch's worker starts
  # publishing under the window's name.
  defp open_branch(sid, child, window, profile, prompt) do
    isolation = if child.worktree, do: :worktree, else: :shared

    record(sid, window, :branch_spawned, %{
      name: profile,
      isolation: isolation,
      prompt: prompt,
      session_id: child.id,
      worktree: child.worktree,
      git_branch: child.git_branch
    })

    if child.worktree do
      record(sid, window, :worktree_created, %{
        path: child.worktree,
        git_branch: child.git_branch,
        managed: true
      })
    end

    attach({:local, child.workspace}, child.id, %{
      workspace: child.workspace,
      profile: profile,
      title: prompt,
      as: {sid, window}
    })
  end

  # A session opened again brings its branches' windows back, as long as the daemon
  # still has those sessions.
  defp reopen_branches(sid) do
    for branch <- branches(sid), Worker.whereis(branch.session_id) == nil do
      case Link.call("session.get", %{session_id: branch.session_id}) do
        {:ok, %{} = row} ->
          attach({:local, row["workspace"]}, branch.session_id, %{
            workspace: row["workspace"],
            profile: branch.profile,
            title: branch.prompt,
            as: {sid, branch.window}
          })

        {:error, _reason} ->
          record(sid, branch.window, :window_dismissed, %{})
      end
    end

    :ok
  end

  # A new session on a repository with no brief, or a stale one, starts the librarian
  # as a branch when the workspace config asks for it (`memory_auto_refresh`, the
  # default). Off in tests and for anyone who would rather run `/memory refresh`.
  defp refresh_brief_if_asked(sid, workspace) do
    config = Config.load(workspace)

    if config.memory != false and config.memory_auto_refresh != false do
      case Link.call("memory.get", %{workspace: workspace}) do
        {:ok, %{"status" => status}} when status in ["absent", "stale"] ->
          prompt = if status == "absent", do: @first_prompt, else: @refresh_prompt
          _ = dispatch(sid, "librarian", prompt)
          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp close_branch(sid, branch) do
    Worker.detach(branch.session_id)
    record(sid, branch.window, :window_dismissed, %{})
  end

  defp worktree_branch(sid, path) do
    case branch(sid, path) do
      nil -> {:error, "no branch #{path}"}
      %{worktree: nil} -> {:error, "#{path} shares this checkout; there is nothing to merge"}
      branch -> {:ok, branch}
    end
  end

  # A line this client writes into the session's journal, for the screen and for the
  # next time the session is opened.
  defp record(sid, window, type, data) do
    event = %Troupe.Event{
      session_id: sid,
      agent_path: window,
      type: type,
      ts: System.system_time(:millisecond),
      data: data
    }

    for kept <- Journal.append(sid, [event]), do: Events.publish(kept)
    :ok
  end

  defp first_line(text) do
    case text |> to_string() |> String.split("\n", parts: 2) do
      ["" | _] -> "branch"
      [line | _] -> String.slice(String.trim(line), 0, 72)
    end
  end

  defp start_child(spec) do
    case DynamicSupervisor.start_child(Troupe.Remote.Sessions, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp workspace(sid) do
    case Worker.whereis(sid) && Worker.attachment(sid) do
      %{workspace: workspace} when is_binary(workspace) -> workspace
      _ -> File.cwd!()
    end
  end

  defp summary(row, origin) do
    %{
      id: row["id"],
      title: row["title"] || row["workspace"] || row["id"],
      owner: row["owner"],
      team: nil,
      profile: row["profile"],
      state: Worker.session_state(row["state"]) || :dormant,
      status: row["status"],
      tokens: row["tokens"],
      cost: row["cost"],
      updated_at: to_ms(row["last_active_at"] || row["created_at"]),
      origin: origin,
      branches: [],
      workspace: row["workspace"]
    }
  end

  defp entry(%{} = e) do
    %{
      name: e["name"],
      path: e["path"],
      dir?: e["kind"] == "directory",
      size: e["size"] || 0,
      workspace: nil
    }
  end

  defp to_ms(nil), do: nil

  defp to_ms(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp to_ms(n) when is_integer(n), do: n

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp describe(:ok), do: :ok
  defp describe({:ok, _}), do: :ok
  defp describe({:error, reason}), do: {:error, message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message(%{message: text}) when is_binary(text), do: text
  defp message(:not_attached), do: "this session is not open"
  defp message(:disconnected), do: "the daemon is not reachable"
  defp message(reason), do: inspect(reason)
end
