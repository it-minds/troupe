defmodule Troupe.Client.Remote do
  @moduledoc """
  `Troupe.Client` over the remote contract.

  Plane-level calls go to the plane connection for the origin; session-level
  ones go to the worker connection that owns the attached session. Attaching is
  the only thing that does both: `session.open` on the plane says which worker
  and with which token, and a worker connection is started for it.

  What a remote session cannot do says so in words rather than failing
  silently: there is no worktree to merge, no local watcher, and settings
  belong to the plane.
  """

  @behaviour Troupe.Client

  alias Troupe.Client.{Events, Repositories, Sensitive}
  alias Troupe.Config
  alias Troupe.Protocol.ClientUpdate
  alias Troupe.Remote.{Capability, Credentials, Discovery, Journal, Plane, RPC, Tokens, Worker}
  alias Troupe.UI.NewSession

  ## Session-scoped

  @impl true
  def subscribe(sid), do: Events.subscribe(sid)

  @impl true
  def unsubscribe(sid), do: Events.unsubscribe(sid)

  # The journal, and the question this client has out to the person in the window, which
  # is never written down (`Worker.asking/1`).
  @impl true
  def events(sid), do: Journal.all(sid) ++ Worker.asking(sid)

  @impl true
  def earlier(sid, before), do: Worker.earlier(sid, before)

  @impl true
  def commands(sid) do
    with %{plane_url: plane, team: team} when is_binary(plane) <- attachment(sid),
         {:ok, profiles} <- profiles({:remote, plane}, team) do
      Enum.map(profiles, & &1.name)
    else
      _ -> []
    end
  end

  # The worker's harness lists the same table a daemon's does, with its bundle's agents;
  # what a pod cannot do is marked `local` in it and the palette says so.
  @impl true
  def command_table(sid) do
    case Worker.rpc(sid, "commands.list", %{}) do
      {:ok, %{"commands" => commands}} when is_list(commands) -> commands
      _ -> []
    end
  end

  @impl true
  def context(sid) do
    label =
      case attachment(sid) do
        %{plane_url: plane} when is_binary(plane) -> plane <> "/" <> sid
        _ -> sid
      end

    # A screen, not a session: a refused file shows the defaults and says why.
    config =
      case Config.resolve(File.cwd!()) do
        {:ok, config, _layers} -> config
        {:error, error} -> %Config{warnings: [Exception.message(error)]}
      end

    {label, config}
  end

  @impl true
  def capability(sid) do
    status = Worker.status(sid)

    status.state
    |> Capability.of(status.scopes, status.up?, status.error)
    |> Map.put(:relayed?, Map.get(status, :relayed?, false))
    |> Map.put(:only_me?, Map.get(status, :only_me?, false))
    |> Map.put(:sensitive?, Map.get(status, :sensitive?, false))
    |> Map.put(:always_allow?, Map.get(status, :always_allow?, false))
    |> Map.put(:attach_artifact?, Map.get(status, :attach_artifact?, false))
  end

  @impl true
  def dispatch(_sid, _name, _args),
    do: {:error, "a remote session runs one profile; create another session from HQ"}

  # A pod starts no branches, so command mode's chooser has nothing to start here
  # (TUI Decision 155), and the pod's checkout is its only one.
  @impl true
  def agent_definition(_sid, _name),
    do: {:error, "a remote session runs one profile; create another session from HQ"}

  @impl true
  def worktree_status(_sid), do: {:ok, []}

  @impl true
  def start_command(_sid, _agent, _name, _arguments, _mode),
    do: {:error, "a remote session runs one profile; create another session from HQ"}

  # A pod's session never watches, so no comment starts a branch of it.
  @impl true
  def adopt_branch(_sid, _child, _profile, _prompt),
    do: {:error, "watch mode runs where the files are"}

  @impl true
  def send_input(sid, _path, text), do: describe(Worker.input(sid, text))

  @impl true
  def run_command(sid, name, arguments), do: describe(Worker.run_command(sid, name, arguments))

  # On the worker pod, in its working copy: where the session runs (root Decision 813).
  @impl true
  def shell_run(sid, command, agent?) do
    case Worker.shell_run(sid, command, agent?) do
      {:ok, %{"run_id" => run_id}} -> {:ok, run_id}
      {:ok, other} -> {:error, "unexpected shell.run answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def shell_cancel(sid, run_id), do: describe(Worker.shell_cancel(sid, run_id))

  @impl true
  def approve(sid, call_id, decision, answer),
    do: describe(Worker.approve(sid, call_id, decision, answer))

  # The contract has no question method: an answer is input, which is how a
  # remote agent's `ask_user` reaches it.
  @impl true
  def answer(sid, call_id, text), do: describe(Worker.answer(sid, call_id, text))

  # A pod's session asks nothing at its start: onboarding runs on the person's own machine
  # (root Decision 826), and its brief is the pod's.
  @impl true
  def answer_local(_sid, _id, _key),
    do: {:error, "a session on the platform asks nothing at its start"}

  @impl true
  def edit_todo(sid, _path, change), do: describe(Worker.edit_todo(sid, change))

  @impl true
  def switch_profile(sid, _path, name), do: describe(Worker.switch_profile(sid, name))

  # The same `session.goal.*` a daemon session answers: the harness keeps the goal, so a
  # pod's session has one exactly as a laptop's does.
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
  def compact(sid), do: describe(Worker.compact(sid))

  # On the platform only the plane wakes a session, and a root there that crashes on its
  # log puts its session to sleep at once.
  @impl true
  def repair(_sid),
    do:
      {:error,
       "a session on the platform is woken by its plane, which cannot wake it past an event it cannot read"}

  @impl true
  def cancel_branch(sid, _path), do: describe(Worker.cancel(sid))

  # A pod session has one window, its own, which stays: letting go of it under the screen
  # sent what was typed next to this machine's daemon (Decision 843).
  @impl true
  def dismiss(_sid, _path), do: {:error, Troupe.Client.own_window()}

  @impl true
  def merge(_sid, _path), do: {:error, "a remote session has no local worktree to merge"}

  @impl true
  def discard(_sid, _path), do: {:error, "a remote session has no local worktree to discard"}

  # What is in force in the session on its pod, over its own connection (`config.get`
  # naming it): the worker profile's settings and rules, what the platform enforces, the
  # terms it was created with and its repository's files, each with where it came from.
  @impl true
  def settings(sid) do
    case Worker.rpc(sid, "config.get", %{session_id: sid}) do
      {:ok, %{"keys" => keys} = answer} when is_list(keys) -> {:ok, answer}
      {:ok, other} -> {:error, "unexpected config.get answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def put_setting(_sid, _key, _value, _scope), do: {:error, Troupe.Settings.pod_line()}

  @impl true
  def watch(_sid, _enabled?), do: {:error, "watch mode runs where the files are"}

  @impl true
  def watch_status(_sid), do: %{enabled: false, backend: nil}

  @impl true
  def mcp_status(_sid), do: []

  @impl true
  def sources(_sid), do: {:error, "a remote session's MCP servers and skills are its profile's"}

  @impl true
  def manage_sources(_sid, _method, _params),
    do: {:error, "a remote session's MCP servers and skills are its profile's"}

  # A pod's agents are its profile's bundle, read-only here: the worker reads and checks
  # them, and says so in the same words it refuses a write with, which are never sent.
  @pod_agents "On the platform the agents come from the profile's bundle and are read-only here: " <>
                "an administrator changes them on the console's " <>
                "Configure → Configuration bundles; ask one if you are not."

  @impl true
  # Named by the session and no path, which is what a session's token may read: its own
  # agents, its bundle's, with the profile they came from (root #594).
  def agents(sid, "agents.list", params) do
    case Worker.rpc(sid, "agents.list", Map.put(params, :session_id, sid)) do
      {:ok, %{} = listed} -> {:ok, Map.put(listed, "read_only", @pod_agents)}
      {:ok, other} -> {:error, "unexpected agents.list answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def agents(sid, method, params) when method in ~w(agents.get agents.validate) do
    case Worker.rpc(sid, method, Map.put(params, :session_id, sid)) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, other} -> {:error, "unexpected #{method} answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def agents(_sid, method, _params) when method in ~w(agents.put agents.delete),
    do: {:error, @pod_agents}

  def agents(_sid, method, _params), do: {:error, "unknown method #{method}"}

  @impl true
  def memory(_sid, _command), do: {:error, "the project brief lives on the worker"}

  @impl true
  def memory_facts(_sid), do: {:error, "the project brief lives on the worker"}

  @impl true
  def forget_fact(_sid, _id), do: {:error, "the project brief lives on the worker"}

  # The pod's checkout has instruction files of its own, and `context.get` is a session
  # method a worker answers; the paths are the pod's, shown as they come.
  # A session on the plane is reached through it already; what is offered is a session on
  # this computer (root #58).
  @impl true
  def remote_steering(_sid, _verb) do
    {:error, "this session runs on the plane already: /steer offers a session on this computer"}
  end

  # A pod session's invitations are made at the plane, where each is the session's grant
  # made visible (root #765).
  @impl true
  def invites(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> invite_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp invite_on(plane, sid, :list) do
    case call(plane, "session.invites", %{session_id: sid}) do
      {:ok, %{"invites" => invites}} -> {:ok, Troupe.Client.Invites.line(invites)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # A sensitive session's profile may refuse the invitation, or hold it for a team
  # administrator's yes, which nobody is invited before (root #1239).
  defp invite_on(plane, sid, {:invite, person, role}) do
    case call(plane, "session.invite", %{session_id: sid, subject: person, role: role}) do
      {:ok, %{"waiting" => true} = answer} -> {:ok, Sensitive.waiting(answer)}
      {:ok, answer} -> {:ok, Troupe.Client.Invites.invited(answer, role)}
      {:error, reason} -> {:error, Sensitive.sharing_refused(reason) || refusal(reason)}
    end
  end

  defp invite_on(plane, sid, {:uninvite, person}) do
    case call(plane, "session.uninvite", %{session_id: sid, subject: person}) do
      {:ok, answer} -> {:ok, Troupe.Client.Invites.uninvited(answer, person)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # Whose a pod session is, at the plane, which holds the row (root #1169). The status
  # line's mark follows the answer at once; the log's line follows where a pod holds it.
  @impl true
  def share(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> share_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  # A pod session marked sensitive by its owner, at the plane, one-way (root #1239): the
  # status line's mark follows the answer at once; the log's line follows from the pod.
  @impl true
  def sensitive(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> sensitive_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp sensitive_on(plane, sid, :status) do
    case call(plane, "session.get", %{session_id: sid}) do
      {:ok, %{"sensitive" => %{} = mark}} ->
        {:ok, Sensitive.already(mark)}

      {:ok, %{"your_role" => role}} when role not in [nil, "owner"] ->
        {:ok, "This session is not sensitive."}

      {:ok, %{} = _row} ->
        {:ok, Sensitive.ask(:plane)}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  defp sensitive_on(plane, sid, :mark) do
    case call(plane, "session.sensitive.set", %{session_id: sid, sensitive: true}) do
      {:ok, %{} = row} ->
        _ = Worker.sensitive(sid)
        {:ok, Sensitive.set(row)}

      {:error, reason} ->
        {:error, Sensitive.refused(reason)}
    end
  end

  # How long a pod session lasts, at the plane, whose row its sweep reads (root #1209);
  # changed, the log's `session_lifespan_changed` follows where a pod holds it.
  @impl true
  def lifespan(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> lifespan_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp lifespan_on(plane, sid, :status) do
    case call(plane, "session.get", %{session_id: sid}) do
      {:ok, %{} = row} -> {:ok, Troupe.Client.Lifespan.status(row)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp lifespan_on(plane, sid, {:set, word}) do
    case call(plane, "session.lifespan.set", %{session_id: sid, lifespan: word}) do
      {:ok, %{} = row} ->
        {:ok, Troupe.Client.Lifespan.set(row["lifespan"] || word, row["erases_at"])}

      {:error, %{message: "forbidden"} = error} ->
        {:error, Troupe.Client.Lifespan.forbidden(error[:data])}

      {:error, %{code: -32_601}} ->
        {:error, Troupe.Client.Lifespan.not_known()}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  # What the harness proposed in a pod session (root #1208): the open one as its log said
  # it; a yes at the plane, as this person, which tells the pod; a no to the session.
  @impl true
  def proposal(sid, verb) do
    case {verb, Worker.open_proposal(sid)} do
      {:status, open} -> {:ok, Troupe.Client.Proposal.status(open)}
      {_verb, nil} -> {:error, Troupe.Client.Proposal.status(nil)}
      {:yes, open} -> accept(sid, open)
      {no, open} -> answer_proposal(sid, open["id"], Atom.to_string(no))
    end
  end

  defp accept(sid, open) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) ->
        case call(plane, "session.proposal.accept", %{session_id: sid, id: open["id"], edits: %{}}) do
          {:ok, %{} = answer} ->
            {:ok, Troupe.Client.Proposal.accepted(answer)}

          {:error, %{code: -32_601}} ->
            {:error, "this plane does not turn on a proposed trigger yet"}

          {:error, %{data: %{"reason" => said}}} when is_binary(said) ->
            {:error, said}

          {:error, reason} ->
            {:error, refusal(reason)}
        end

      _ ->
        {:error, message(:not_attached)}
    end
  end

  defp answer_proposal(sid, id, decision) do
    said =
      if decision == "never",
        do: "not proposed again for this report",
        else: "not now: not asked again in this session"

    case Worker.answer_proposal(sid, id, decision) do
      {:error, %{data: %{"reason" => reason}}} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, refusal(reason)}
      _answered -> {:ok, said}
    end
  end

  # Which configuration a pod session runs on, at the plane, which holds the pin (root
  # #1177); raised, the log's `config_upgraded` follows where a pod holds it.
  @impl true
  def bundle(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> bundle_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp bundle_on(plane, sid, :status) do
    case call(plane, "session.get", %{session_id: sid}) do
      {:ok, %{} = row} -> {:ok, Troupe.Client.Bundle.status(row)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp bundle_on(plane, sid, :update) do
    case call(plane, "session.bundle.raise", %{session_id: sid}) do
      {:ok, %{} = row} ->
        {:ok, Troupe.Client.Bundle.raised(row)}

      # The agent was working: the plane keeps the raise for when it is done.
      {:error, %{message: "conflict", data: %{"raise_to" => to}}} ->
        {:ok, Troupe.Client.Bundle.kept(to)}

      {:error, %{message: "forbidden"} = error} ->
        {:error, Troupe.Client.Bundle.forbidden(error[:data])}

      {:error, %{code: -32_601}} ->
        {:error, "this plane does not update a session's configuration yet"}

      {:error, %{data: %{"reason" => said}}} when is_binary(said) ->
        {:error, said}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  # The GitHub repositories a pod session holds, at the plane, which keeps the list and
  # tells the pod (root #1207); the log's `session_repository_changed` follows.
  @impl true
  def repositories(sid, verb) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) -> repositories_on(plane, sid, verb)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp repositories_on(plane, sid, :list) do
    case call(plane, "session.get", %{session_id: sid}) do
      {:ok, %{} = row} -> {:ok, Repositories.list(row)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp repositories_on(plane, sid, {:add, repository}) do
    params = %{session_id: sid, repository: Repositories.param(repository)}

    # A clone takes as long as git takes; the plane waits for the pod as long.
    case Plane.call(plane, "session.repository.add", params, 320_000) do
      {:ok, %{} = row} -> {:ok, Repositories.added(row, Repositories.name(repository))}
      {:error, reason} -> {:error, repository_refusal(reason)}
    end
  end

  defp repositories_on(plane, sid, {:remove, full}) do
    case call(plane, "session.repository.remove", %{session_id: sid, repository: full}) do
      {:ok, %{}} -> {:ok, Repositories.removed(full)}
      {:error, reason} -> {:error, repository_refusal(reason)}
    end
  end

  defp repository_refusal(%{message: "forbidden"} = error), do: Repositories.forbidden(error[:data])
  defp repository_refusal(%{code: -32_601}), do: Repositories.too_old()

  defp repository_refusal(%{data: %{"reason" => "busy", "detail" => detail}})
       when is_binary(detail),
       do: detail

  defp repository_refusal(%{data: %{"reason" => said}}) when is_binary(said), do: said
  defp repository_refusal(reason), do: refusal(reason)

  defp share_on(plane, sid, :status) do
    case call(plane, "session.get", %{session_id: sid}) do
      {:ok, %{} = row} -> {:ok, Troupe.Client.Share.status(row)}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  defp share_on(plane, sid, {:set, visibility}) do
    case call(plane, "session.visibility.set", %{session_id: sid, visibility: visibility}) do
      # Held for a team administrator's yes (root #1239): nothing changed yet.
      {:ok, %{"waiting" => true} = answer} ->
        {:ok, Sensitive.waiting(answer)}

      {:ok, %{} = row} ->
        _ = Worker.visibility(sid, row["visibility"])
        {:ok, Troupe.Client.Share.set(row)}

      {:error, %{message: "forbidden"} = error} ->
        {:error, Sensitive.sharing_refused(error) || Troupe.Client.Share.forbidden(error[:data])}

      {:error, %{code: -32_601}} ->
        {:error, "this plane does not give a session to a team after it started yet"}

      {:error, reason} ->
        {:error, refusal(reason)}
    end
  end

  @doc """
  The invitations to the person signed in at `plane` (`invites.list`): each the session, its
  title, whose it is, the role and who invited them, newest first. A plane from before
  invitations lists none.
  """
  @spec invitations(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def invitations(plane) do
    case call(plane, "invites.list", %{}) do
      {:ok, %{"invites" => invites}} when is_list(invites) -> {:ok, invites}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, refusal(reason)}
    end
  end

  # A pod session is archived at the plane, which holds its row; a worker refuses it. Only
  # the owner may, and the plane says so in `data.required_role`.
  @impl true
  def archive(sid, archived?) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) ->
        case call(plane, Troupe.Client.Archive.method(archived?), %{session_id: sid}) do
          {:ok, _row} ->
            {:ok, Troupe.Client.Archive.said(archived?)}

          {:error, %{message: "forbidden"} = error} ->
            {:error, Troupe.Client.Archive.forbidden(error[:data], archived?)}

          {:error, reason} ->
            {:error, archive_refusal(plane_refusal(reason))}
        end

      _ ->
        {:error, message(:not_attached)}
    end
  end

  # A pod session's name and its place at the top are the plane's, as archiving it is.
  @impl true
  def rename(sid, title) do
    at_plane(sid, "session.title.set", %{session_id: sid, title: title}, :rename, fn row ->
      Troupe.Client.Marks.renamed(if is_map(row), do: row["title"])
    end)
  end

  @impl true
  def keep(sid, kept?) do
    at_plane(sid, Troupe.Client.Marks.keep_method(kept?), %{session_id: sid}, :keep, fn _row ->
      Troupe.Client.Marks.kept(kept?)
    end)
  end

  defp at_plane(sid, method, params, what, said) do
    case attachment(sid) do
      %{plane_url: plane} when is_binary(plane) ->
        case call(plane, method, params) do
          {:ok, row} ->
            {:ok, said.(row)}

          {:error, %{message: "forbidden"} = error} ->
            {:error, Troupe.Client.Marks.forbidden(error[:data], what)}

          {:error, %{data: %{"reason" => reason}}} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, mark_refusal(plane_refusal(reason), what)}
        end

      _ ->
        {:error, message(:not_attached)}
    end
  end

  defp mark_refusal(:unsupported, :rename), do: "this plane does not rename sessions yet"
  defp mark_refusal(:unsupported, :keep), do: "this plane does not keep sessions at the top yet"
  defp mark_refusal(reason, _what), do: archive_refusal(reason)

  defp archive_refusal(:unsupported), do: "this plane does not archive sessions yet"
  defp archive_refusal(:not_found), do: "the plane has no such session"
  defp archive_refusal(reason), do: message(reason)

  # The plane's sentence where it gave one: who may not be invited, and why.
  defp refusal(%{data: %{"reason" => reason}}) when is_binary(reason), do: reason
  defp refusal(%{"data" => %{"reason" => reason}}) when is_binary(reason), do: reason
  defp refusal(reason), do: message(reason)

  @impl true
  def instructions(sid) do
    case Worker.rpc(sid, "context.get", %{}) do
      {:ok, %{"files" => _} = answer} -> {:ok, Troupe.Client.Instructions.line(answer, nil)}
      {:ok, other} -> {:error, "unexpected context.get answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_list(sid, path) do
    case Worker.fs_list(sid, path) do
      {:ok, %{"entries" => entries}} -> {:ok, Enum.map(List.wrap(entries), &entry/1)}
      {:ok, entries} when is_list(entries) -> {:ok, Enum.map(entries, &entry/1)}
      {:ok, other} -> {:error, "unexpected fs.list answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fs_read(sid, path) do
    case Worker.fs_read(sid, path) do
      {:ok, %{"content" => content}} when is_binary(content) -> {:ok, content}
      {:ok, %{"content_base64" => encoded}} when is_binary(encoded) -> decode(encoded)
      {:ok, %{"blob" => blob, "preview" => preview}} -> {:ok, fetch_blob(sid, blob, preview)}
      {:ok, content} when is_binary(content) -> {:ok, content}
      {:ok, other} -> {:error, "unexpected fs.read answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  # A pod's session is one session, its windows its agents: one scratchpad.
  @impl true
  def scratch_read(sid, _window, path), do: fs_read(sid, path)

  @impl true
  def fs_upload(sid, path, content), do: describe(Worker.fs_upload(sid, path, content))

  # The pod fetches the artifact's files over its control link, for the person here.
  @impl true
  def attach_artifact(sid, artifact, version) do
    case Worker.fs_upload_artifact(sid, artifact, version) do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, other} -> {:error, "unexpected fs.upload answer: #{inspect(other)}"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def upload_fits(sid, size), do: Worker.upload_fits(sid, size)

  @impl true
  def stop_session(sid) do
    Worker.detach(sid)
    :ok
  end

  @impl true
  def has_session?(sid), do: Worker.whereis(sid) != nil

  @impl true
  def idle?(_sid), do: false

  # A pod session is forked by the plane (root Decision 812): a new row, key and placement,
  # whose pod copies the parent's history before it starts. Answered as `session.create`
  # is, and attached the same way.
  @impl true
  def fork_session(sid) do
    case attachment(sid) do
      %{plane_url: plane} = info when is_binary(plane) -> fork_on(plane, sid, info)
      _ -> {:error, message(:not_attached)}
    end
  end

  defp fork_on(plane, sid, info) do
    case call(plane, "session.fork", %{session_id: sid, command_id: RPC.command_id()}) do
      {:ok, %{"session_id" => child} = result} ->
        attach({:remote, plane}, child, %{
          endpoint: result["endpoint"],
          token: result["token"],
          state: Worker.session_state(result["state"]) || :active,
          profile: info[:profile],
          team: info[:team],
          title: info[:title]
        })

      {:ok, other} ->
        {:error, "unexpected session.fork answer: #{inspect(other)}"}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  ## Fleet-scoped

  @impl true
  def teams({:remote, plane}) do
    case call(plane, "me") do
      {:ok, %{} = me} -> {:ok, identity_of(plane, me).teams}
      {:ok, _other} -> {:ok, []}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def teams(_origin), do: {:error, :unsupported}

  @impl true
  def profiles({:remote, plane}, team) do
    case call(plane, "profiles.list", params(%{team: team})) do
      {:ok, list} -> {:ok, list |> unwrap("profiles") |> Enum.map(&profile/1)}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def profiles(_origin, _team), do: {:error, :unsupported}

  @doc """
  The profiles the person may use, as `profiles.list` answers them, row by row and
  unshaped: `/profiles` and `troupe profiles` say more of each than HQ's picker does.
  """
  @spec profile_rows(Troupe.Client.origin()) :: {:ok, [map()]} | {:error, term()}
  def profile_rows({:remote, plane}) do
    case call(plane, "profiles.list") do
      {:ok, list} -> {:ok, list |> unwrap("profiles") |> Enum.filter(&is_map/1)}
      {:error, reason} -> {:error, plane_refusal(reason)}
    end
  end

  def profile_rows(_origin), do: {:error, :unsupported}

  @doc """
  What one profile gives a session of the person's, as `profile.get` answers it for
  them: `{:error, :not_found}` for one they may not use, `{:error, :unsupported}` from a
  plane from before the method.
  """
  @spec profile_page(Troupe.Client.origin(), String.t()) :: {:ok, map()} | {:error, term()}
  def profile_page({:remote, plane}, name) do
    case call(plane, "profile.get", %{name: name}) do
      {:ok, %{} = page} -> {:ok, page}
      {:ok, other} -> {:error, "unexpected profile.get answer: #{inspect(other)}"}
      {:error, reason} -> {:error, plane_refusal(reason)}
    end
  end

  def profile_page(_origin, _name), do: {:error, :unsupported}

  defp plane_refusal(%{code: -32_005}), do: :not_found
  defp plane_refusal(%{code: -32_601}), do: :unsupported
  defp plane_refusal(%{code: _code} = error), do: RPC.describe(error)
  defp plane_refusal(reason) when is_atom(reason), do: reason
  defp plane_refusal(reason), do: message(reason)

  # With the plane down there is still something true to say: the sessions this
  # client is attached to are on screen and streaming, so they are listed from
  # what the worker connections know rather than the list coming back empty
  # (Decision 79).
  @impl true
  def sessions({:remote, plane} = origin, filter) do
    params =
      params(%{
        team: filter[:team] || filter["team"],
        state: filter[:state] || filter["state"],
        archived: if(filter[:archived] || filter["archived"], do: true)
      })

    case call(plane, "sessions.list", params) do
      {:ok, list} ->
        rows = Enum.map(unwrap(list, "sessions"), &summary(&1, origin))
        # A laptop's session offered for steering is the laptop's to archive, never listed so.
        {:ok, if(params[:archived], do: rows, else: rows ++ offered(plane, origin))}

      {:error, :plane_down} ->
        {:ok, attached(origin)}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def sessions(_origin, _filter), do: {:error, :unsupported}

  # Laptops' sessions offered to this person for steering from another device (root #58):
  # their own from another of their laptops, and those shared with them, after the plane's
  # own. A plane from before them has no `remote.list`, and lists none.
  defp offered(plane, origin) do
    case call(plane, "remote.list", %{}) do
      {:ok, list} -> list |> unwrap("sessions") |> Enum.map(&offered_summary(&1, origin))
      {:error, _none} -> []
    end
  end

  defp offered_summary(row, origin) do
    owner = row["owner_name"] || row["owner"]
    online? = row["state"] == "online"

    where =
      [owner && "#{owner}'s laptop", row["workspace"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    %{
      id: row["id"],
      title: if(where == "", do: row["id"], else: where),
      owner: row["owner"],
      team: nil,
      profile: nil,
      state: if(online?, do: :active, else: :dormant),
      status: if(online?, do: "online", else: offline(row["offline_since"])),
      tokens: nil,
      cost: nil,
      updated_at: updated_at(row["offered_at"]),
      origin: origin,
      branches: [],
      parent: nil,
      workspace: row["workspace"],
      kind: "remote",
      sync: nil,
      device: nil
    }
  end

  defp offline(since) when is_binary(since), do: "offline since #{since}"
  defp offline(_since), do: "offline"

  @impl true
  def get_session({:remote, _plane} = origin, sid) do
    with {:ok, rows} <- sessions(origin, %{}) do
      case Enum.find(rows, &(&1.id == sid)) do
        nil -> {:error, "not_found"}
        row -> {:ok, row}
      end
    end
  end

  def get_session(_origin, _sid), do: {:error, :unsupported}

  @impl true
  def create_session({:remote, plane} = origin, params) do
    body =
      params(%{
        team: team_name(plane, params[:team]),
        profile: params[:profile],
        agent: params[:agent],
        title: params[:title],
        source: source(params[:source]),
        # The team's, as the desktop app sends; `private` (`/new --only-me`, `troupe run
        # --only-me`) is its owner's and the people they invite, on the team's profile all
        # the same. Never a sealed session, which is this computer's daemon's.
        visibility: params[:visibility] || "team",
        # How long it lasts, where it is not normal (root #1209).
        lifespan: if(params[:lifespan] in ["throwaway", "persistent"], do: params[:lifespan]),
        # Sensitive from its start, one-way (`/new --sensitive`, `troupe run --sensitive`,
        # root #1239); absent otherwise, which a plane from before takes as it always did.
        sensitive: if(params[:sensitive] == true, do: true),
        # The GitHub repositories it starts on (`/new --repo`, `troupe run --repo`), each
        # `owner/name` or `{owner, name, ref}`; with none the plane is sent none.
        repositories: repositories_param(params[:repositories]),
        prompt: params[:prompt] || "",
        command_id: RPC.command_id()
      })

    with {:ok, %{"session_id" => sid} = result} <- call(plane, "session.create", body),
         {:ok, result} <- placed(plane, sid, result, params[:on_wait]) do
      attach(origin, sid, %{
        endpoint: result["endpoint"],
        token: result["token"],
        state: :active,
        profile: params[:profile],
        team: params[:team],
        only_me: body[:visibility] == "private",
        sensitive: body[:sensitive] == true,
        repositories: repository_names(result["repositories"]),
        title: params[:title] || params[:prompt]
      })
    else
      {:ok, other} ->
        {:error, "unexpected session.create answer: #{inspect(other)}"}

      {:error, reason} ->
        # More than one of the person's teams may use the profile and none was named: the
        # names go to the caller whole, to ask which, never flattened into a sentence.
        case NewSession.teams_to_choose(reason) do
          nil -> {:error, message(reason)}
          teams -> {:error, {:choose_team, teams}}
        end
    end
  end

  def create_session(_origin, _params), do: {:error, :unsupported}

  # A profile with no room below its ceiling makes the session wait for a place: the plane
  # answers `pending` with `retry_after_ms` and holds the prompt. Given `on_wait`, the wait
  # is the caller's to show, once per answer, and `token.mint` is asked again as the plane
  # says until the session is placed; `on_wait` answering `:stop` ends the wait, and the
  # session waits on at the plane by itself. Without it, the session is attached as it
  # stands and its worker connection asks for a token as it reconnects.
  defp placed(plane, sid, %{"state" => "pending"} = answer, on_wait) when is_function(on_wait, 1) do
    case on_wait.(answer) do
      :stop ->
        {:error, "stopped waiting for a place; #{sid} starts by itself when one frees"}

      _go_on ->
        Process.sleep(max(answer["retry_after_ms"] || 2_000, 250))

        case call(plane, "token.mint", %{session_id: sid}) do
          {:ok, %{} = next} -> placed(plane, sid, next, on_wait)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp placed(_plane, _sid, answer, _on_wait), do: {:ok, answer}

  @doc """
  The plane's own rows of the person's sessions, as `sessions.list` answers them: the
  agent each runs as and when it was last active, which the new-session screen starts
  from ("start like last time", the last profile used).
  """
  @spec session_rows(Troupe.Client.origin()) :: {:ok, [map()]} | {:error, term()}
  def session_rows({:remote, plane}) do
    case call(plane, "sessions.list", %{}) do
      {:ok, list} -> {:ok, list |> unwrap("sessions") |> Enum.filter(&is_map/1)}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  def session_rows(_origin), do: {:error, :unsupported}

  # Browsing uses mode `read`, which never wakes a dormant session; the first
  # activating action is what opens it with mode `activate`, from the worker.
  # A laptop's session offered for steering (root #58, `kind: "remote"`): attached with
  # the token `remote.open` mints, at the relay's address, where the laptop answers it as
  # its own daemon would. Asked again for the next token, and again where it went.
  @impl true
  def open_session({:remote, plane} = origin, sid, mode, opts) do
    if Keyword.get(opts, :kind) == "remote",
      do: open_offered(plane, sid),
      else: open_pod(plane, origin, sid, mode, Keyword.get(opts, :only_me, false))
  end

  def open_session(_origin, _sid, _mode, _opts), do: {:error, :unsupported}

  # `only_me` is what the listing said of the row opened (`session.open` does not say it),
  # for the status line.
  defp open_pod(plane, origin, sid, mode, only_me) do
    case call(plane, "session.open", %{session_id: sid, mode: to_string(mode)}) do
      {:ok, %{} = result} ->
        attach(origin, sid, %{
          endpoint: result["endpoint"],
          token: result["token"],
          state: Worker.session_state(result["state"]) || :active,
          profile: result["profile"],
          team: result["team"],
          only_me: only_me,
          title: result["title"],
          # Whose it is, where the plane says (root #1169), which `/share` and the log's
          # `session_visibility_changed` then change.
          visibility: result["visibility"],
          owner?: result["role"] == "owner",
          # What it works on, as the plane said, which the log's `session_repository_changed`
          # then changes.
          repositories: repository_names(result["repositories"])
        })

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  defp open_offered(plane, sid) do
    case relay(plane, sid) do
      {:ok, %{endpoint: endpoint, token: token}} ->
        with {:ok, _journal} <- start_journal(plane, sid, %{}),
             {:ok, _worker} <-
               start_session_child({Worker,
                [
                  session_id: sid,
                  # Nothing for this client's plane to mint or reopen: the laptop's daemon
                  # holds the session, and `remote.open` is asked for the next token.
                  plane_url: nil,
                  endpoint: endpoint,
                  token: token,
                  relocate: fn -> relay(plane, sid) end,
                  renew: fn ->
                    with {:ok, %{token: token}} <- relay(plane, sid), do: {:ok, token}
                  end,
                  impl: __MODULE__,
                  state: :active,
                  isolation: :remote
                ]}) do
          {:ok, sid}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp start_session_child(spec) do
    case DynamicSupervisor.start_child(Troupe.Remote.Sessions, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # `remote.open`: the relay's address, on this plane, and a token for this session alone.
  # A laptop away is `unavailable`, with since when.
  defp relay(plane, sid) do
    case call(plane, "remote.open", %{session_id: sid}) do
      {:ok, %{"token" => token} = result} when is_binary(token) ->
        {:ok, %{endpoint: relay_endpoint(plane, result["endpoint"]), token: token}}

      {:ok, other} ->
        {:error, "unexpected remote.open answer: #{inspect(other)}"}

      {:error, %{code: _code} = error} ->
        {:error, RPC.describe(error)}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  defp relay_endpoint(plane, "/" <> _ = path), do: String.trim_trailing(plane, "/") <> path
  defp relay_endpoint(_plane, endpoint) when is_binary(endpoint), do: endpoint
  defp relay_endpoint(plane, _none), do: String.trim_trailing(plane, "/") <> "/v1/relay/session"

  # A private session is claimed by the daemon that would seal it, not through a plane.
  @impl true
  def claim_session(_origin, _sid), do: {:error, :unsupported}

  @impl true
  def whoami({:remote, plane}) do
    case call(plane, "me") do
      {:ok, %{} = me} ->
        {:ok, identity_of(plane, me)}

      {:error, reason} ->
        {:error, message(reason)}
    end
  end

  def whoami(_origin), do: {:error, :unsupported}

  @doc """
  What the plane's administrators say this machine should talk to: provider, URL, auth
  style and models, never a key (`me.client_defaults`).
  """
  @spec client_defaults(Troupe.Client.origin()) :: {:ok, map()} | {:error, term()}
  def client_defaults({:remote, plane}) do
    case call(plane, "me.client_defaults") do
      {:ok, %{} = defaults} -> {:ok, defaults}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @doc """
  The organisation's memory documents this person's machine reads (`me.memory`, root
  issue #55), signed as the plane signs them, for the daemon to check and keep.
  `{:error, :unsupported}` from a plane from before memory.
  """
  @spec memory(Troupe.Client.origin()) :: {:ok, map()} | {:error, term()}
  def memory({:remote, plane}) do
    case call(plane, "me.memory") do
      {:ok, %{} = answer} -> {:ok, answer}
      {:ok, other} -> {:error, {:unexpected, other}}
      {:error, %{code: -32_601}} -> {:error, :unsupported}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  @impl true
  def fleet_status({:remote, plane} = origin) do
    status = Plane.status(plane)

    %{
      up?: status.up?,
      origin: origin,
      principal: status.principal,
      scopes: status.scopes,
      error: status.error,
      # The plane's refusal of this version, as the sentence that says what to run
      # (Decision 868): what HQ shows instead of "unreachable".
      update_required:
        case status.error do
          {:update_required, sentence} -> sentence
          _other -> nil
        end,
      # A newer version the plane recommends, as one quiet line with what to run
      # (Decision 874); nothing at or past it.
      suggest:
        ClientUpdate.suggestion(
          Map.get(status, :client_update),
          to_string(Application.spec(:troupe, :vsn))
        )
    }
  end

  def fleet_status(origin),
    do: %{up?: false, origin: origin, principal: nil, scopes: [], error: :unsupported}

  @impl true
  def subscribe_fleet({:remote, plane}), do: Plane.subscribe_fleet(plane)
  def subscribe_fleet(_origin), do: {:error, :unsupported}

  ## Connections

  @doc """
  Starts (or finds) the connection to a plane. Discovery and the stored refresh
  token are read here, so a plane that was never logged in to fails with
  `:logged_out` instead of a socket error.
  """
  @spec connect(String.t()) :: {:ok, Troupe.Client.origin()} | {:error, term()}
  def connect(plane_url) do
    url = Discovery.base(plane_url)

    with {:ok, _plane} <- Tokens.load(url),
         {:ok, _pid} <- start_plane(url) do
      {:ok, {:remote, url}}
    end
  end

  @doc "The planes this machine is logged in to."
  @spec planes() :: [map()]
  def planes, do: Credentials.list()

  @doc "The plane `troupe --remote` opens with no argument."
  @spec default_plane() :: Troupe.Client.origin() | nil
  def default_plane do
    case Credentials.fetch() do
      {:ok, %{plane_url: url}} -> {:remote, url}
      :error -> nil
    end
  end

  @doc "Attaches a session: a journal for its transcript, a worker connection for its stream."
  @spec attach(Troupe.Client.origin(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def attach({:remote, plane}, sid, info) do
    if info[:token], do: Tokens.put_session_token(sid, info[:token])

    with {:ok, _journal} <- start_journal(plane, sid, info),
         {:ok, _worker} <- start_worker(plane, sid, info) do
      {:ok, sid}
    end
  end

  def attach(_origin, _sid, _info), do: {:error, :unsupported}

  defp start_plane(url) do
    case DynamicSupervisor.start_child(
           Troupe.Remote.Connections,
           {Plane, [plane_url: url]}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_journal(plane, sid, info) do
    case DynamicSupervisor.start_child(
           Troupe.Remote.Sessions,
           {Journal, [session_id: sid, plane_url: plane, title: info[:title]]}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_worker(plane, sid, info) do
    spec =
      {Worker,
       [
         session_id: sid,
         plane_url: plane,
         endpoint: info[:endpoint],
         state: info[:state] || :active,
         profile: info[:profile],
         team: info[:team],
         only_me: info[:only_me] == true,
         sensitive: info[:sensitive] == true,
         title: info[:title],
         visibility: info[:visibility],
         owner?: info[:owner?] == true,
         repositories: info[:repositories]
       ]}

    case DynamicSupervisor.start_child(Troupe.Remote.Sessions, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Internals

  defp call(plane, method, params \\ %{}), do: Plane.call(plane, method, params)

  @doc "The sessions this client has worker connections for, as HQ rows."
  @spec attached(Troupe.Client.origin()) :: [Troupe.Client.summary()]
  def attached({:remote, plane} = origin) do
    Troupe.Client.Registry
    |> Registry.select([{{{:remote_worker, :"$1"}, :_, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn sid ->
      case Worker.attachment(sid) do
        %{plane_url: ^plane} = info -> [attached_summary(sid, info, origin)]
        _ -> []
      end
    end)
  end

  def attached(_origin), do: []

  defp attached_summary(sid, info, origin) do
    %{
      id: sid,
      title: info[:title] || sid,
      owner: nil,
      team: info[:team],
      profile: info[:profile],
      state: info[:state] || :active,
      status: "attached",
      tokens: nil,
      cost: nil,
      updated_at: nil,
      origin: origin,
      branches: [],
      parent: nil,
      workspace: nil,
      kind: nil,
      sync: nil,
      device: nil
    }
  end

  defp attachment(sid) do
    case Worker.attachment(sid) do
      %{} = info -> info
      _ -> nil
    end
  end

  defp describe(:ok), do: :ok
  defp describe({:ok, _result}), do: :ok
  defp describe({:error, reason}), do: {:error, message(reason)}

  defp message(:read_only), do: "this session is read-only"
  defp message(:not_attached), do: "not attached to this session"
  defp message(:disconnected), do: "not connected to the worker"
  defp message(:lost), do: "lost the session; trying again now"
  defp message({:lost, why}), do: "lost the session: #{why}"
  defp message(:plane_down), do: "the plane is unreachable"
  defp message({:update_required, sentence}), do: sentence
  defp message(:timeout), do: "the server did not answer in time"
  defp message(:logged_out), do: "not signed in; run troupe login <plane-url>"
  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: inspect(reason)

  defp repositories_param([_ | _] = list), do: Enum.map(list, &Repositories.param/1)
  defp repositories_param(_none), do: nil

  # A session row's or an open's repositories by `owner/name`; `nil` where it said none,
  # as a plane from before the list does.
  defp repository_names(list) when is_list(list),
    do: for(%{"owner" => _, "name" => _} = entry <- list, do: Repositories.name(entry))

  defp repository_names(_none), do: nil

  defp params(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp source(nil), do: %{type: "empty"}
  defp source(%{} = source), do: source

  # `me`, as this client keeps it: for `troupe whoami`, for the HQ header, and for
  # naming a team the plane way. Remembered whenever it is fetched, by either door.
  defp identity_of(plane, me) do
    identity = %{
      sub: me["subject"] || me["sub"],
      name: me["display_name"] || me["name"],
      teams: me |> Map.get("teams", []) |> List.wrap() |> Enum.map(&team/1),
      plane_url: plane,
      workspace: nil
    }

    Tokens.put_identity(plane, identity)
    identity
  end

  # The plane matches `team` by *name*; this client addresses a team by its id, which
  # the live plane makes a GUID. A known id goes out as its name; anything else as it
  # came (Decision 97).
  defp team_name(plane, team) when is_binary(team) do
    case Tokens.identity(plane) do
      {:ok, %{teams: teams}} ->
        Enum.find_value(teams, team, fn t -> if t.id == team, do: t.name end)

      :error ->
        team
    end
  end

  defp team_name(_plane, team), do: team

  # The contract answers a list; the live plane wraps it in an object under
  # the method's noun (Decision 93).
  defp unwrap(%{} = envelope, key), do: List.wrap(Map.get(envelope, key, []))
  defp unwrap(list, _key), do: List.wrap(list)

  defp team(%{} = team), do: %{id: team["id"], name: team["name"] || team["id"]}
  defp team(name) when is_binary(name), do: %{id: name, name: name}
  defp team(_other), do: %{id: nil, name: "?"}

  defp profile(%{} = profile) do
    %{
      name: profile["name"] || "?",
      description: profile["description"] || offering(profile),
      health: profile["health"] || health(profile),
      capacity: capacity(profile["capacity"], profile["active_sessions"])
    }
  end

  defp profile(other),
    do: %{
      name: to_string(other),
      description: "",
      health: "unknown",
      capacity: %{free: nil, total: nil}
    }

  # The contract's `{free, total}`, or the live plane's total with the sessions
  # on it counted separately.
  defp capacity(%{} = capacity, _active), do: %{free: capacity["free"], total: capacity["total"]}

  defp capacity(total, active) when is_integer(total) and is_integer(active),
    do: %{free: max(total - active, 0), total: total}

  defp capacity(total, _active) when is_integer(total), do: %{free: nil, total: total}
  defp capacity(_capacity, _active), do: %{free: nil, total: nil}

  # The live plane reports its pods rather than a verdict; the verdict is drawn here. A pod
  # the operator removed is listed `gone` until the plane forgets it, and is nobody's to
  # look at: it is not a pod of the profile's, healthy or not.
  defp health(%{"pods" => pods, "healthy_pods" => healthy})
       when is_list(pods) and is_integer(healthy) do
    pods = Enum.reject(pods, &(is_map(&1) and &1["gone"] == true))

    cond do
      pods == [] -> "no pods"
      healthy == length(pods) -> "ok"
      healthy == 0 -> "down"
      true -> "degraded"
    end
  end

  defp health(_profile), do: "unknown"

  defp offering(%{"channel" => channel} = profile) when is_binary(channel),
    do:
      Enum.map_join(
        Enum.reject([channel, profile["bundle_version"]], &is_nil/1),
        " · ",
        &to_string/1
      )

  defp offering(_profile), do: ""

  defp summary(%{} = session, origin) do
    %{
      id: session["id"],
      title: session["title"] || session["id"],
      owner: session["owner"],
      # The owner's name, where the plane has one (#931); a view shows the subject without it.
      owner_name: session["owner_name"],
      team: session["team"],
      profile: session["profile"],
      state: Worker.session_state(session["state"]) || :dormant,
      status: session["status"],
      tokens: session["tokens"],
      cost: session["cost"] || from_micros(session["cost_micros"]),
      updated_at: updated_at(session["updated_at"] || session["last_active_at"]),
      origin: origin,
      branches: [],
      parent: nil,
      workspace: nil,
      kind: session["kind"] || "team",
      # Who may open a pod session (`team`, or `private`: its owner and the people invited),
      # and this person's part in it, which together say "only you".
      visibility: session["visibility"],
      your_role: session["your_role"],
      # How long it lasts, and when a throwaway one goes (root #1209); normal from a plane
      # from before lifespans.
      lifespan: Troupe.Client.Lifespan.of(session),
      erases_at: session["erases_at"],
      # Since when, and by what, it is sensitive (root #1239); nil while it is not.
      sensitive: Sensitive.of(session["sensitive"]),
      # A plane cannot say how this machine's copy of a private session stands, only that
      # it is waiting to be erased (root Decision 756).
      sync: if(session["state"] == "erasure_pending", do: "erasure_pending"),
      device: session["device"],
      archived: session["archived"] == true
    }
  end

  defp from_micros(micros) when is_integer(micros), do: micros / 1_000_000
  defp from_micros(_other), do: nil

  defp updated_at(value) when is_integer(value), do: value

  defp updated_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp updated_at(_value), do: nil

  defp entry(%{} = entry) do
    %{
      name: entry["name"] || Path.basename(entry["path"] || ""),
      path: entry["path"] || entry["name"],
      dir?: entry["kind"] == "directory",
      size: entry["size"] || 0,
      workspace: nil
    }
  end

  defp entry(name) when is_binary(name),
    do: %{name: Path.basename(name), path: name, dir?: false, size: 0, workspace: nil}

  defp decode(encoded) do
    case Base.decode64(encoded) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "the server sent content this client could not decode"}
    end
  end

  # A file over the inline limit arrives as a blob; the preview is what is shown
  # if fetching the rest fails.
  defp fetch_blob(sid, blob, preview) do
    case Worker.blob(sid, blob) do
      {:ok, %{"data" => encoded}} ->
        case Base.decode64(encoded) do
          {:ok, content} -> content
          :error -> preview || ""
        end

      {:ok, %{"content" => content}} when is_binary(content) ->
        content

      _ ->
        preview || ""
    end
  end
end
