defmodule Troupe.Tools do
  @moduledoc """
  The tool set, and the gate every call passes through.

  The allowlist and the permission map are enforced here, in the harness. A model
  that asks for a tool the active profile does not have gets an error tool result and
  the tool never runs — the tool list sent to the provider is a convenience for the
  model, not the security boundary.
  """

  alias Troupe.Agent.Definition
  alias Troupe.Config.Permissions
  alias Troupe.Session.{Approvals, ClientTools}
  alias Troupe.{Skills, Tool}
  alias Troupe.Tool.{Ctx, Result}
  alias Troupe.Tools.{GoalComplete, PublishArtifact}

  @builtins [
    Troupe.Tools.ReadFile,
    Troupe.Tools.WriteFile,
    Troupe.Tools.EditFile,
    Troupe.Tools.ListFiles,
    Troupe.Tools.Grep,
    Troupe.Tools.Shell,
    # The only two tools that copy between `session:/` and a shared root. They are in
    # the built-in set rather than added by the worker so that a profile's allowlist can
    # name them whether or not the session turns out to have a team volume.
    Troupe.Tools.Publish,
    Troupe.Tools.Import,
    Troupe.Tools.TodoWrite,
    Troupe.Tools.TodoRead,
    Troupe.Tools.Delegate,
    # A subagent started in the background, stopped by the agent that started it (Decision 853).
    Troupe.Tools.StopChild,
    Troupe.Tools.Finish,
    # What a branch of this session (Decision 646) said when it finished.
    Troupe.Tools.ReadBranch,
    # The project brief (Decision 649): the one file a tool may write unasked.
    Troupe.Tools.Remember,
    # The repository's facts the prompt does not carry, asked for (Decision 838).
    Troupe.Tools.Recall,
    # The rest of a cut shell or grep result (Decision 650).
    Troupe.Tools.ReadOutput,
    # The four the TUI's harness had and the core lacked (Decisions 651 and 652).
    Troupe.Tools.AskUser,
    Troupe.Tools.WebFetch,
    Troupe.Tools.GitRead,
    Troupe.Tools.Glob,
    # Onboarding another tool's files into Troupe's own (Decision 823).
    Troupe.Tools.OnboardWrite,
    # A document shown beside the chat (Decision 870), on every call: never gated here.
    Troupe.Tools.Show,
    # And revised in place, wherever `show` is and on every call, never gated either: a
    # tool that came and went would change the front of every prompt.
    Troupe.Tools.Patch
  ]

  # The task list's tools, and the model calls a turn makes before a profile that did not
  # name them is offered them (Decision 793).
  @task_list ~w(todo_write todo_read)
  @task_list_after 10

  # Tools a profile has only when it names them (Decision 823): `onboard_write` writes the
  # files that decide what runs, which only a profile made for it does (the librarian no
  # longer, Decision 835), and an agent with every tool (`build`) is neither offered it nor
  # let call it.
  @named_only ~w(onboard_write)

  @doc """
  The built-in tools by name, each with whether it runs as a task or inside the agent
  (`:inline`), which never asks: what a permission rule's tool is checked against when a
  file is read.
  """
  @spec builtins() :: [{String.t(), :task | :inline}]
  def builtins, do: Enum.map(@builtins, &{Tool.name(&1), Tool.mode(&1)})

  @doc """
  Every tool available, built-ins plus anything registered in `:extra_tools` that this
  session has (`Troupe.Tool.available?/2`).

  The extension point exists so a later MCP adapter can register remote tools as
  ordinary `Troupe.Tool` implementations without touching the agent loop, and the
  test suite uses it to install tools that misbehave on purpose.

  A session id adds the tools an attached client hosts for *that* session. They are
  per-session because the connection offering them is: a personal MCP connection belongs
  to one person on one session, and a pod-wide list would hand it to everybody.
  """
  @spec all(String.t() | nil) :: [Tool.handle()]
  def all(session_id \\ nil), do: @builtins ++ extra(session_id) ++ mcp(session_id)

  @doc """
  The tools that come and go during a session: the pod's and the session's MCP servers'
  and those a person's client offers. An agent takes them as a turn's first model call
  finds them and offers those for the rest of the turn (`Ctx.turn_tools`, Decision 871),
  so a server that comes back with another list, a sign-in that completes or a person's
  tools leaving change the tools at the next turn, not in the middle of one. An agent
  restarted in the middle of a turn offers them as the turn began (`Troupe.Agent.Hold`,
  Decision 876).
  """
  @spec mcp(String.t() | nil) :: [Tool.handle()]
  def mcp(session_id), do: remote() ++ local(session_id) ++ hosted(session_id)

  defp hosted(nil), do: []
  defp hosted(session_id), do: ClientTools.list(session_id)

  # The workspace's own MCP servers (Decision 654): per session, because the config is.
  defp local(nil), do: []
  defp local(session_id), do: Troupe.Session.MCP.tools(session_id)

  # The host's own, less those it says this session does not have (`Tool.available?/2`): a
  # worker's GitHub tools exist only for a session created with a repository.
  defp extra(session_id) do
    :troupe_core
    |> Application.get_env(:extra_tools, [])
    |> Enum.filter(&Tool.available?(&1, session_id))
  end

  # Tools discovered from MCP servers, as values rather than modules. They go through
  # everything below exactly as a built-in does — which is the point.
  defp remote do
    case Application.get_env(:troupe_core, :remote_tools) do
      nil -> []
      fun when is_function(fun, 0) -> fun.()
      tools when is_list(tools) -> tools
    end
  end

  @spec fetch(String.t(), String.t() | nil) ::
          {:ok, Tool.handle()} | {:error, {:unknown_tool, String.t()}}
  def fetch(name, session_id \\ nil) do
    case Enum.find(all(session_id), &(Tool.name(&1) == name)) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, tool}
    end
  end

  @doc "The tools a profile may use, in a stable order."
  @spec for_definition(Definition.t(), String.t() | nil) :: [Tool.handle()]
  def for_definition(%Definition{} = definition, session_id \\ nil),
    do: profile_tools(all(session_id), definition)

  defp profile_tools(tools, definition) do
    Enum.filter(tools, fn tool ->
      name = Tool.name(tool)

      named?(definition, name) and
        Definition.permission(definition, name, Tool.default_permission(tool)) != :deny
    end)
  end

  # A named-only tool is a profile's when its list names it, not when it has every tool.
  defp named?(%Definition{tools: :all}, name), do: name not in @named_only
  defp named?(%Definition{}, _name), do: true

  @doc """
  The tools a profile may use in one agent's context: everything `for_definition/2`
  gives it, plus the `skill` tool when the session's bundle has skills the profile
  lists, less any MCP server this session's team is not entitled to.

  The skill tool is scoped to the context rather than registered pod-wide because it
  reads the bundle *this session* is pinned to, and two sessions on one pod may be
  pinned to different versions. The entitlement filter is here for the same reason and
  one more: **discovery stays pod-wide**. Asking four servers for their tool list at
  every create would put somebody else's latency on the create path, so the pod
  discovers once and each session composes its own list from what was discovered. A
  session that may not use `jira` does not see `mcp.jira.*`; the pod still knows the
  tools exist.
  """
  @spec available(Definition.t(), Ctx.t()) :: [Tool.handle()]
  def available(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> offered(ctx)
    |> entitled_servers(ctx.bundle)
    |> Kernel.++(skill_tools(definition, ctx))
    |> Kernel.++(loop_tools(ctx))
    |> task_list(definition, ctx)
  end

  # The task list (Decision 793). A profile that names `todo_write`, as `plan` and
  # `orchestrate` do, has it on every call: the list is what it is for. One with every tool,
  # as `build`, is offered it while there is a list and once its turn has made ten model
  # calls, and not before: a model that answers with one call a response paid a call for
  # a list and one for each update, on tasks of a few calls, whatever its prompt said. A
  # call to it unoffered still runs, as the profile allows it.
  #
  # Except to a model that binds its thinking to the tools it was made under (Decision
  # 867): there they are offered from the first call, since a tool added in the middle of
  # a session makes every thinking block before it one an enforced account refuses.
  defp task_list(tools, %Definition{tools: :all}, %Ctx{todos: [], turn_calls: calls} = ctx)
       when calls < @task_list_after do
    if ctx.binds_thinking,
      do: tools,
      else: Enum.reject(tools, &(Tool.name(&1) in @task_list))
  end

  defp task_list(tools, _definition, _ctx), do: tools

  # The profile's tools, with the MCP servers' and the person's clients' as the turn's
  # first call found them: one that comes or goes changes the tools at the next turn, never
  # in the middle of one.
  defp offered(definition, %Ctx{turn_tools: held} = ctx) when is_list(held),
    do: profile_tools(@builtins ++ extra(ctx.session_id) ++ held, definition)

  defp offered(definition, %Ctx{} = ctx), do: for_definition(definition, ctx.session_id)

  # The skills as the turn's first call found them (Decision 876), for the profile in force:
  # a skill file added, removed or renamed in the middle of a turn changes the tool at the
  # next turn, and a call to one that went is told so.
  defp skill_tools(definition, %Ctx{turn_skills: %{} = held}),
    do: held |> Skills.offered(definition) |> Skills.tools_for()

  # The person's own skills are read beside the workspace (Decision 700), and only when
  # there is one to read beside: a context built without a workspace has no layer. What
  # its `skills.json` links from outside the repository waits for the session to trust it
  # (Decision 829).
  defp skill_tools(definition, %Ctx{workspace: %Troupe.Workspace{} = ws} = ctx),
    do: Skills.tools(ctx.bundle, definition, ws.root_real, trusted: ws.trusted?)

  defp skill_tools(definition, %Ctx{} = ctx), do: Skills.tools(ctx.bundle, definition, nil)

  # A loop's structured verdict (Decision 679), on the turns a running loop started and
  # no others, and outside the profile's list: it changes nothing but whether the loop
  # goes on, and a loop whose agent could not say "done" would only ever stop at its cap.
  # To a model that binds its thinking to its tools, on every call of the root agent, which
  # is the one a loop runs on (Decision 871), and refused outside a loop's turns.
  defp loop_tools(%Ctx{loop: loop}) when is_binary(loop), do: [GoalComplete]
  defp loop_tools(%Ctx{binds_thinking: true, agent_path: ["root"]}), do: [GoalComplete]
  defp loop_tools(%Ctx{}), do: []

  defp entitled_servers(tools, %{entitlements: %{"mcp_servers" => names}}) when is_list(names) do
    entitled = MapSet.new(names)

    Enum.reject(tools, fn tool ->
      case Troupe.MCP.server_of(Tool.name(tool)) do
        nil -> false
        server -> not MapSet.member?(entitled, server)
      end
    end)
  end

  defp entitled_servers(tools, _bundle), do: tools

  @doc """
  The tool specs to send a provider, with descriptions rendered for this session.
  """
  @spec specs(Definition.t(), Ctx.t()) :: [Troupe.LLM.Request.tool_spec()]
  def specs(%Definition{} = definition, %Ctx{} = ctx) do
    definition
    |> available(ctx)
    |> Enum.map(fn tool ->
      %{name: Tool.name(tool), description: Tool.describe(tool, ctx), schema: Tool.schema(tool)}
    end)
  end

  @doc """
  Which credential a call to this tool would go out as, or `nil` where the question does
  not arise.

  Only an MCP server has two answers, so only an MCP tool gets one. A built-in runs as
  the pod and a client-hosted tool runs on somebody's laptop; neither is a credential
  anybody chose, and an `identity` on those events would be a field that always said the
  same thing.
  """
  @spec identity_of(String.t(), Ctx.t()) :: Troupe.Protocol.Principal.t() | nil
  def identity_of(name, %Ctx{} = ctx) do
    with server when is_binary(server) <- Troupe.MCP.server_of(name),
         %Troupe.MCP.Tool{server: ^server} = tool <- find_mcp_tool(name, ctx) do
      Troupe.MCP.identity(tool_server(tool), ctx)
    else
      _ -> nil
    end
  end

  defp find_mcp_tool(name, ctx) do
    Enum.find(all(ctx.session_id), &(Tool.name(&1) == name))
  end

  # The tool carries its server's name; the configured server is where the mode is. A
  # tool whose server has gone from the configuration answers as a profile one, which is
  # what it was before anybody wrote a mode.
  defp tool_server(%Troupe.MCP.Tool{server: name}) do
    Enum.find(
      configured_servers(),
      %Troupe.MCP.Server{name: name, url: ""},
      &(&1.name == name)
    )
  end

  defp configured_servers do
    case Application.get_env(:troupe_core, :mcp_servers) do
      fun when is_function(fun, 0) -> fun.()
      list when is_list(list) -> list
      _none -> []
    end
  end

  @doc """
  Decide whether a call may proceed at all, before anything is spawned.

  Returns `{:run, module, mode}`, or a `Result` the agent hands straight back to the
  model without running anything. A per-tool rule that denies the call (#658) refuses it
  here, with its arguments, whatever kind of tool it is.
  """
  @spec authorize(String.t(), Definition.t(), Ctx.t(), map()) ::
          {:run, Tool.handle(), :task | :inline} | {:reject, Result.t()}
  def authorize(name, %Definition{} = definition, %Ctx{} = ctx, args \\ %{}) do
    case Enum.find(loop_tools(ctx), &(Tool.name(&1) == name)) do
      nil -> authorize_listed(name, definition, ctx, args)
      tool when is_binary(ctx.loop) -> {:run, tool, Tool.mode(tool)}
      _outside_a_loop -> {:reject, Result.error(ctx.call_id, name, {:no_loop, name})}
    end
  end

  defp authorize_listed(name, definition, ctx, args) do
    case fetch(name, ctx.session_id)
         |> or_entitled(name, ctx)
         |> or_scoped(name, definition, ctx)
         |> or_gone(name, ctx) do
      {:error, reason} ->
        {:reject, Result.error(ctx.call_id, name, reason)}

      {:ok, tool} ->
        cond do
          not (Definition.allows_tool?(definition, name) and named?(definition, name)) ->
            {:reject, Result.error(ctx.call_id, name, {:not_allowed, name})}

          Definition.permission(definition, name, Tool.default_permission(tool)) == :deny ->
            {:reject, Result.error(ctx.call_id, name, {:denied_by_policy, name})}

          true ->
            unless_denied(tool, name, args, ctx)
        end
    end
  end

  defp unless_denied(tool, name, args, ctx) do
    case rule(name, args, ctx) do
      {:deny, rule} -> {:reject, Result.error(ctx.call_id, name, {:denied_by_rule, name, rule})}
      _other -> {:run, tool, Tool.mode(tool)}
    end
  end

  # What the configuration's per-tool rules say about this call (#658), or `nil`.
  defp rule(name, args, %Ctx{config: %{permissions: [_ | _] = rules}} = ctx) do
    root = if ctx.workspace, do: ctx.workspace.root_real
    Permissions.decide(rules, name, args, root)
  end

  defp rule(_name, _args, _ctx), do: nil

  # An MCP server the session's team is not entitled to (ARCHITECTURE.md section 9): its
  # tools were never offered to this session, so a call to one is unknown, as a
  # session-scoped tool the profile does not qualify for is. `available/2` narrows the list
  # the provider is sent the same way; this is the check that holds when a model names
  # the tool anyway, since the list is a convenience for the model and never the boundary.
  defp or_entitled({:ok, tool}, name, %Ctx{bundle: %{entitlements: %{"mcp_servers" => names}}})
       when is_list(names) do
    case Troupe.MCP.server_of(Tool.name(tool)) do
      nil -> {:ok, tool}
      server -> if server in names, do: {:ok, tool}, else: {:error, {:unknown_tool, name}}
    end
  end

  defp or_entitled(found, _name, _ctx), do: found

  # The pod-wide list first, then the session-scoped tools. A name found in neither is
  # unknown; a session-scoped tool the profile does not qualify for is unknown too,
  # because for that profile it was never offered.
  defp or_scoped({:ok, tool}, _name, _definition, _ctx), do: {:ok, tool}

  defp or_scoped({:error, reason}, name, definition, ctx) do
    case Enum.find(skill_tools(definition, ctx), &(Tool.name(&1) == name)) do
      nil -> {:error, reason}
      tool -> {:ok, tool}
    end
  end

  # A tool this turn was offered whose server or client has gone since (Decision 871): it
  # is still in the tools the model is sent until the turn ends, and a call to it is told so.
  # A person's own tool says whose it was and that their client left, in this turn or a
  # later one; a name nobody ever offered the session stays unknown.
  defp or_gone({:error, {:unknown_tool, _name}} = unknown, name, %Ctx{turn_tools: held} = ctx) do
    case departed(name, ctx.session_id) do
      {:ok, gone} ->
        {:error, {:client_tool_gone, name, gone.who, gone.reason}}

      :error ->
        if is_list(held) and Enum.any?(held, &(Tool.name(&1) == name)),
          do: {:error, {:tool_gone, name}},
          else: unknown
    end
  end

  defp or_gone(found, _name, _ctx), do: found

  defp departed(name, session_id) when is_binary(session_id) do
    if String.starts_with?(name, ClientTools.prefix()),
      do: ClientTools.departed(session_id, name),
      else: :error
  end

  defp departed(_name, _session_id), do: :error

  @doc """
  Run a `:task` tool, blocking on approval if the profile asks for one.

  Called from inside a task under the agent's `Agent.Tasks` supervisor, never from
  the agent process: it can block for a human, and it must be killable.
  """
  @spec run_task(Tool.handle(), map(), Definition.t(), Ctx.t()) :: Result.t()
  def run_task(tool, args, %Definition{} = definition, %Ctx{} = ctx) do
    name = Tool.name(tool)

    case permission(tool, name, args, definition, ctx) do
      {ask, rule} when ask in [:ask, :must_ask] ->
        answered(tool, name, args, ctx, ask(ctx, name, args, ask == :must_ask, rule))

      {:auto, _rule} ->
        execute(tool, args, ctx)

      {:deny, nil} ->
        Result.error(ctx.call_id, name, {:denied_by_policy, name})

      {:deny, rule} ->
        Result.error(ctx.call_id, name, {:denied_by_rule, name, rule})
    end
  end

  # A call the tool says a person must answer (`onboard_write` into the config directory,
  # Decision 823) is asked about whatever the profile grants, and the session's
  # `auto_approve` does not answer it; a profile's `deny` still denies.
  #
  # Then the configuration's per-tool rules (#658), the strictest that matches holding: a
  # `deny` refuses, an `ask` asks as a must-answer call does, whatever the profile's `auto`,
  # `auto_approve` and a standing "allow for the session" say, and an `allow` runs a call
  # that would have asked, unless a person must answer it. Answers the permission and the
  # rule that decided it, `nil` where none did.
  defp permission(tool, name, args, definition, ctx) do
    case Definition.permission(definition, name, Tool.default_permission(tool)) do
      :deny ->
        {:deny, nil}

      permission ->
        must_ask? = Tool.must_ask?(tool, args)

        case rule(name, args, ctx) do
          {:deny, rule} -> {:deny, rule}
          {:ask, rule} -> {:must_ask, rule}
          _none when must_ask? -> {:must_ask, nil}
          {:allow, rule} -> {:auto, rule}
          nil -> {permission, nil}
        end
    end
  end

  # The call as the gate answered it. A publication the person aimed there runs for whom
  # they chose, their `visibility` and `owner` laid over the model's, and is told they
  # chose: the one answer here that carries more than a word, since a delegation's call is
  # deferred to the agent rather than run in a task. A no to one carries their word back.
  defp answered(tool, _name, args, ctx, :allow), do: execute(tool, args, ctx)

  defp answered(tool, _name, args, ctx, {:allow, given}),
    do: execute(tool, PublishArtifact.as_answered(args, given), %{ctx | answer: given})

  defp answered(_tool, name, _args, ctx, {:deny, :unattended}),
    do: Result.error(ctx.call_id, name, {:denied_unattended, name})

  defp answered(_tool, name, _args, ctx, {:deny, %{"reason" => reason}}),
    do: Result.error(ctx.call_id, name, {:denied, name, reason})

  defp answered(_tool, name, _args, ctx, _denied),
    do: Result.error(ctx.call_id, name, {:denied, name})

  defp ask(ctx, name, args, always?, rule) do
    Approvals.request(
      ctx.session_id,
      %{
        call_id: ctx.call_id,
        tool: name,
        args: args,
        agent_path: ctx.agent_path,
        always: always?
      }
      |> put_rule(rule)
      |> put_publication(name, args)
    )
  end

  defp put_rule(req, nil), do: req
  defp put_rule(req, rule), do: Map.put(req, :rule, Permissions.to_json(rule))

  # A publication asks with what the gate shows and the person aims: the title, the kind,
  # the files' count, and the audience and owner the model proposed, or none.
  defp put_publication(req, "publish_artifact", args),
    do: Map.put(req, :publication, PublishArtifact.publication(args))

  defp put_publication(req, _name, _args), do: req

  @doc """
  Run a tool and normalise whatever it returns into a `Result`.

  A tool that raises, throws or exits becomes an error result — the one place the
  "let it crash" rule is deliberately suspended, because the model needs the failure
  as feedback in order to correct itself.
  """
  @spec execute(Tool.handle(), map(), Ctx.t()) :: Result.t()
  def execute(tool, args, %Ctx{} = ctx) do
    name = Tool.name(tool)

    try do
      case Tool.invoke(tool, args, ctx) do
        {:ok, content} ->
          Result.ok(ctx.call_id, name, text(content))

        {:ok, content, %{fields: fields} = updates} ->
          Result.ok(ctx.call_id, name, text(content), meta(Map.delete(updates, :fields), fields))

        {:ok, content, updates} ->
          Result.ok(ctx.call_id, name, text(content), %{updates: updates})

        {:defer, instruction} ->
          %Result{
            call_id: ctx.call_id,
            name: name,
            ok?: true,
            content: "",
            meta: %{defer: instruction}
          }

        {:error, reason} ->
          Result.error(ctx.call_id, name, text(reason))
      end
    rescue
      error ->
        Result.error(ctx.call_id, name, {:tool_crashed, Exception.message(error)})
    catch
      :throw, value ->
        Result.error(ctx.call_id, name, {:tool_crashed, "threw #{inspect(value)}"})

      :exit, reason ->
        Result.error(ctx.call_id, name, {:tool_crashed, "exited with #{inspect(reason)}"})
    end
  end

  # The fields for the call's event travel apart from the agent's updates, so a tool that
  # returns only fields hands the agent no updates to apply (Decision 837).
  defp meta(updates, fields) when map_size(updates) == 0, do: %{fields: fields}
  defp meta(updates, fields), do: %{updates: updates, fields: fields}

  # A result goes into the log and to the model, both JSON, which holds only UTF-8. Bytes
  # that are not (what a command printed, a binary file, a cut inside a character) are
  # replaced here, where every tool's result passes, rather than in each tool: the log
  # refusing one stopped the session mid-turn (#493).
  defp text(content) when is_binary(content), do: String.replace_invalid(content)
  defp text(other), do: other
end
