defmodule Troupe.Session.Approvals do
  @moduledoc """
  The permission gate for `ask` tools.

  A tool task calls `request/2` and blocks there — the *call* blocks, never the
  agent, which is free to collect other tool results meanwhile. The UI answers with
  `decide/3`. A denial comes back as a readable tool result rather than a crash, so
  the model can pick another approach.

  Callers are monitored: a tool task killed by a cancel or an agent crash is dropped
  from the pending set instead of leaving a reply nobody will ever read.

  Several clients may be watching one session, so two people can answer the same
  prompt a second apart. **First response wins**, and the second gets an
  `approval_resolved` event naming who got there first — silence would leave them
  believing they decided it.

  A session may also run with nobody to ask. `mode: :deny` is for that: every request
  is answered no on the spot, and both the request and the decision still go to the
  log, with the system as the actor, so a person reading the transcript afterwards
  sees what the agent wanted and that it was refused for want of anyone to say yes.
  The default, `:wait`, is what a session with people attached has always done.

  A request made with `always: true` is one its tool says a person must answer
  (Decision 823: `onboard_write` into the config directory), or one a per-tool rule of the
  configuration says asks (#658), which it carries as `rule`: `auto_approve` and a
  standing `allow_session` let it through no more than they would let a refusal through.

  A delegation a person asked to see first (Decision 850) is a request of its own kind,
  `tool: "delegate"` with what the gate shows under `delegation`. `auto_approve` does not
  answer it either: the person opted into seeing that agent's briefs, and a switch that
  says "do not ask me about tool calls" did not take that back. Its answer can carry more
  than a word: the agent it goes to instead (`agent`), the brief as the person edited it
  (`brief`, held to the brief's shape), or a word back to the agent that delegated
  (`reason`, with a denial). `allow_session` lets that agent run unasked for the session,
  rather than every delegation. The caller hears `{:allow, answer}` or `{:deny, answer}`.

  A publication (`tool: "publish_artifact"`) is the other request whose answer carries
  more than a word, with what the gate shows under `publication`: the title, the kind, the
  files' count, and the `visibility` and `owner` the model proposed, `nil` where it proposed
  none. Whom an artifact is for is the person's to say: the answer takes `visibility`
  (`private`, `organisation`, `team:<name>` or `profile:<name>`, its shape alone, since
  membership is the plane's to refuse) and `owner` (`me` or `team`; dropped on a republish,
  whose owner does not change with a version), and an `allow` that
  names no visibility where the model named none is refused, in a sentence, with the
  request still waiting. `allow_session` on one of those is this call's `allow`: a standing
  permission to publish for an audience not yet chosen would be nobody's choice. The
  decision names the `visibility` and `owner` the call ran with and which of them the
  person `edited`, and the caller hears `{:allow, answer}` with them, to run the call as
  the person aimed it.

  Every answer is checked synchronously against its request, so a wrong one, a bare word
  among them, is refused to whoever sent it rather than dropped.
  """

  use GenServer

  alias Troupe.Session.Log
  alias Troupe.Tools.Delegate

  @enforce_keys [:session_id]
  defstruct [
    :session_id,
    mode: :wait,
    auto_approve: false,
    # A platform switch: with it on, a session may not grant itself a standing
    # permission. Every call goes back to the rule the definition carries, which is the
    # platform's, which is the point.
    managed_rules_only: false,
    pending: %{},
    resolved: %{},
    # Decisions read back from the log at start-up. A session that went dormant with an
    # approval answered but its tool not yet finished comes back, re-dispatches the call,
    # and must not ask the same person the same question again.
    decided: %{},
    # Requests read back from the log with no decision and no result yet: the calls a
    # session that slept mid-approval re-dispatches when it comes back.
    awaiting: %{},
    session_allows: MapSet.new()
  ]

  @type decision :: :allow | :deny | :allow_session

  @typedoc """
  What an answer carries besides its word, string-keyed as the protocol sends it: a
  delegation's `agent`, `brief` and `reason`, a publication's `visibility`, `owner` and
  `reason`, each only where given.
  """
  @type answer :: %{optional(String.t()) => term()}

  # -- client -----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: Troupe.Registry.approvals(session_id))
  end

  @doc """
  Ask for permission, blocking until someone decides.

  `:infinity` is deliberate: a human may take a minute, and the timeout that matters
  is the tool's own, enforced by the agent killing the task. `{:deny, :unattended}` is
  the answer of a session running in `:deny` mode, told apart from a person's no so
  the model hears why.
  """
  @spec request(String.t(), map()) ::
          :allow | :deny | {:deny, :unattended} | {:allow, answer()} | {:deny, answer()}
  def request(session_id, %{call_id: _, tool: _} = req) do
    GenServer.call(Troupe.Registry.approvals(session_id), {:request, req}, :infinity)
  catch
    # The gate restarting is not a reason to crash the tool task; it is a denial the
    # model can read and work around.
    :exit, _ -> if answered?(req), do: {:deny, %{}}, else: :deny
  end

  @doc """
  Answer an outstanding request. First response wins.

  `answer` is what a delegation's or a publication's answer carries besides its word. It
  is checked against the request before anything is decided, and a wrong one is answered
  `{:error, sentence}` with the request still waiting: an agent that is not one of the
  subagents offered, a brief missing a part, a publication allowed for nobody in
  particular, any of them on a request that is not that kind. A plain word is checked the
  same way, since a bare `allow` to a publication nobody has aimed is the wrong answer too.
  """
  @spec decide(
          String.t(),
          String.t(),
          decision(),
          Troupe.Protocol.Event.Actor.t() | nil,
          answer()
        ) ::
          :ok | {:error, String.t()}
  def decide(session_id, call_id, decision, actor \\ nil, answer \\ %{}) do
    GenServer.call(
      Troupe.Registry.approvals(session_id),
      {:decide, call_id, decision, actor, answer}
    )
  end

  @doc "Approve everything from now on, as `--auto-approve` does."
  @spec set_auto_approve(String.t(), boolean()) :: :ok
  def set_auto_approve(session_id, value) when is_boolean(value) do
    GenServer.call(Troupe.Registry.approvals(session_id), {:auto_approve, value})
  end

  @doc """
  Whether every request is answered yes on the spot, as `--auto-approve` asks: then
  nothing asks before a tool runs, which is what a workspace's command asks about first
  (Decision 814).
  """
  @spec auto_approve?(String.t()) :: boolean()
  def auto_approve?(session_id),
    do: GenServer.call(Troupe.Registry.approvals(session_id), :auto_approve?)

  @doc "Requests waiting for a decision, for the UI to render."
  @spec pending(String.t()) :: [map()]
  def pending(session_id), do: GenServer.call(Troupe.Registry.approvals(session_id), :pending)

  # -- server -----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    Process.set_label("troupe approvals #{session_id}")

    state = %__MODULE__{
      session_id: session_id,
      mode: Keyword.get(opts, :mode, :wait),
      auto_approve: Keyword.get(opts, :auto_approve, false) == true,
      managed_rules_only: Keyword.get(opts, :managed_rules_only, false)
    }

    # Approvals are durable events precisely so they survive dormancy, and a gate that
    # forgot them on the way back would be the half of that promise nobody kept.
    {:ok, replay(state)}
  end

  defp replay(state) do
    state.session_id
    |> Log.replay()
    |> Enum.reduce(state, &fold/2)
  rescue
    # A session with no log yet — the very first start — has nothing to replay.
    _exception -> state
  catch
    :exit, _reason -> state
  end

  defp fold(%{type: "approval_requested", data: data} = event, state) do
    req =
      %{
        call_id: data["call_id"],
        tool: data["tool"],
        args: data["args"],
        agent_path: data["agent_path"] || event.agent
      }
      |> put_delegation(data["delegation"])
      |> put_publication(data["publication"])
      |> put_rule(data["rule"])

    %{state | awaiting: Map.put(state.awaiting, req.call_id, req)}
  end

  defp fold(%{type: "approval_decided", data: data} = event, state) do
    decision = data["decision"]

    state = %{
      state
      | decided: Map.put(state.decided, data["call_id"], decided_answer(data)),
        awaiting: Map.delete(state.awaiting, data["call_id"]),
        resolved:
          Map.put(state.resolved, data["call_id"], %{
            agent_path: event.agent || data["agent_path"],
            by: describe_actor(event.actor)
          })
    }

    if decision == "allow_session" do
      %{state | session_allows: MapSet.put(state.session_allows, allow_key(data))}
    else
      state
    end
  end

  # A call closed off some other way — timed out, interrupted — is waiting for nobody,
  # whatever its approval says.
  defp fold(%{type: "tool_call_completed", data: %{"call_id" => id}}, state),
    do: %{state | awaiting: Map.delete(state.awaiting, id)}

  defp fold(_event, state), do: state

  defp answer_for("deny"), do: :deny
  defp answer_for(_decision), do: :allow

  # A delegation decided before this tree started is handed back with what its answer
  # carried, read off the decision as it was written: the agent it went to, the brief as
  # edited, the word back.
  defp decided_answer(%{"tool" => "delegate"} = data) do
    {answer_for(data["decision"]), Map.take(data, ~w(agent brief reason edited))}
  end

  # A publication's likewise: whom it is for and whose it is, as the person aimed it.
  defp decided_answer(%{"tool" => "publish_artifact"} = data) do
    {answer_for(data["decision"]), Map.take(data, ~w(visibility owner edited))}
  end

  defp decided_answer(data), do: answer_for(data["decision"])

  # What `allow_session` lets through from then on: a tool, or for a delegation the agent
  # it went to (Decision 850), so `always` for `general` is not `always` for every agent.
  defp allow_key(%{"tool" => "delegate"} = data),
    do: {"delegate", data["agent"] || get_in(data, ["args", "agent"])}

  defp allow_key(data), do: data["tool"]

  defp put_delegation(req, delegation) when is_map(delegation),
    do: Map.put(req, :delegation, delegation)

  defp put_delegation(req, _none), do: req

  defp put_publication(req, publication) when is_map(publication),
    do: Map.put(req, :publication, publication)

  defp put_publication(req, _none), do: req

  defp put_rule(req, rule) when is_map(rule), do: Map.put(req, :rule, rule)
  defp put_rule(req, _none), do: req

  defp managed(:allow_session), do: :allow
  defp managed(decision), do: decision

  @impl GenServer
  def handle_call({:request, req}, from, state) do
    cond do
      state.auto_approve == true and not always?(req) and not delegation?(req) ->
        {:reply, reply(req, :allow, %{}), state}

      MapSet.member?(state.session_allows, request_key(req)) and not always?(req) ->
        {:reply, reply(req, :allow, %{}), state}

      # Already answered, and the tool is only asking again because the session came back
      # and re-dispatched it. Asking a second time would be a question the person has
      # already answered.
      Map.has_key?(state.decided, req.call_id) ->
        {:reply, Map.fetch!(state.decided, req.call_id), state}

      # Nobody to ask. Both events are written all the same — the request so the
      # transcript shows what the agent wanted, the decision so a later activation
      # finds the call answered rather than pending — and the actor is the system,
      # because no person made this choice.
      state.mode == :deny ->
        Log.append(state.session_id, req.agent_path, :approval_requested, requested(req))

        Log.append(
          state.session_id,
          req.agent_path,
          :approval_decided,
          Map.put(describe(req), "decision", "deny")
        )

        resolved = Map.put(state.resolved, req.call_id, resolved_by(req, nil))
        decided = Map.put(state.decided, req.call_id, reply(req, :deny, %{}))
        {:reply, {:deny, :unattended}, %{state | resolved: resolved, decided: decided}}

      true ->
        {caller, _tag} = from
        monitor = Process.monitor(caller)

        pending = Map.put(state.pending, req.call_id, %{from: from, monitor: monitor, req: req})

        # Durable, not ephemeral: an approval outlives dormancy and may be answered
        # days later, so it has to be in the log rather than only on the wire.
        Log.append(state.session_id, req.agent_path, :approval_requested, requested(req))

        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_call({:auto_approve, value}, _from, state) do
    # Turning auto-approve on releases everyone already waiting: the user just said
    # yes to everything, and leaving them blocked would be a surprising deadlock.
    state = if value, do: release_all(state), else: state
    {:reply, :ok, %{state | auto_approve: value}}
  end

  def handle_call(:pending, _from, state) do
    {:reply, Enum.map(state.pending, fn {_id, entry} -> entry.req end), state}
  end

  def handle_call(:auto_approve?, _from, state), do: {:reply, state.auto_approve, state}

  # Every answer is checked against the request first, and a wrong one leaves the request
  # waiting for a right one.
  def handle_call({:decide, call_id, decision, actor, answer}, _from, state) do
    case asked(state, call_id) do
      nil ->
        {:reply, :ok, already_resolved(state, call_id)}

      req ->
        case check_answer(req, decision, answer) do
          {:ok, answer} ->
            {:reply, :ok,
             answer_request(state, call_id, for_this_call(req, decision), actor, answer)}

          {:error, sentence} ->
            {:reply, {:error, sentence}, state}
        end
    end
  end

  # A publication the model aimed at nobody takes no standing permission: the person chose
  # an audience for this call, and "always" would let the next call publish for one not
  # yet chosen. It is this call's allow.
  defp for_this_call(%{publication: %{"visibility" => nil}}, :allow_session), do: :allow
  defp for_this_call(_req, decision), do: decision

  defp answer_request(state, call_id, decision, actor, answer) do
    case Map.pop(state.pending, call_id) do
      {nil, _} ->
        not_pending(state, call_id, decision, actor, answer)

      {entry, pending} ->
        Process.demonitor(entry.monitor, [:flush])
        GenServer.reply(entry.from, reply(entry.req, decision, answer))
        record(%{state | pending: pending}, entry.req, decision, actor, answer)
    end
  end

  defp asked(state, call_id) do
    case Map.fetch(state.pending, call_id) do
      {:ok, entry} -> entry.req
      :error -> Map.get(state.awaiting, call_id)
    end
  end

  # Asked before this tree started, and not yet asked again. Answering a dormant session's
  # approval is what wakes it, so the answer can arrive before the call it answers has
  # gone back out; it is kept, and handed over when that call asks.
  defp not_pending(state, call_id, decision, actor, answer) do
    case Map.fetch(state.awaiting, call_id) do
      {:ok, req} -> record(state, req, decision, actor, answer)
      :error -> already_resolved(state, call_id)
    end
  end

  defp record(state, req, decision, actor, answer) do
    # `allow_session` becomes a plain `allow` where the platform holds the rules: the
    # call in front of the person is answered, and nothing standing is created. The
    # *decision that was made* still goes in the log as `allow`, because an event
    # saying `allow_session` beside a session that allows nothing would be a log that
    # disagreed with itself.
    decision = if state.managed_rules_only, do: managed(decision), else: decision
    data = req |> describe() |> Map.put("decision", Atom.to_string(decision)) |> Map.merge(answer)

    allows =
      if decision == :allow_session,
        do: MapSet.put(state.session_allows, allow_key(data)),
        else: state.session_allows

    Log.append(state.session_id, req.agent_path, :approval_decided, data, actor)

    %{
      state
      | resolved: Map.put(state.resolved, req.call_id, resolved_by(req, actor)),
        decided: Map.put(state.decided, req.call_id, reply(req, decision, answer)),
        awaiting: Map.delete(state.awaiting, req.call_id),
        session_allows: allows
    }
  end

  # -- a delegation's and a publication's answers ----------------------------------

  defp delegation?(req), do: Map.has_key?(req, :delegation)
  defp publication?(req), do: Map.has_key?(req, :publication)

  # A request whose answer carries more than its word, and whose caller hears it.
  defp answered?(req), do: delegation?(req) or publication?(req)

  defp request_key(%{delegation: %{"agent" => agent}}), do: {"delegate", agent}
  defp request_key(req), do: req.tool

  # What the caller waiting on a request hears.
  defp reply(req, decision, answer) do
    word = if decision == :deny, do: :deny, else: :allow
    if answered?(req), do: {word, answer}, else: word
  end

  # A plain answer to a plain request; for a delegation, what the answer carries, held to
  # the request: an agent among the subagents it offered, a brief of the same shape, a
  # word back only with a no. What is written is what runs: an allowing answer always
  # names its agent, and names its brief when the person changed it.
  defp check_answer(%{delegation: delegation}, decision, answer) do
    with :ok <- known_keys(answer),
         {:ok, agent} <- check_agent(delegation, decision, answer["agent"]),
         {:ok, brief} <- check_brief(delegation, decision, answer["brief"]),
         {:ok, reason} <- check_reason(decision, answer["reason"]) do
      {:ok,
       %{"agent" => agent, "brief" => brief, "reason" => reason}
       |> Map.reject(fn {_key, value} -> is_nil(value) end)
       |> with_edited(delegation["brief"])}
    end
  end

  # A publication's: whom it is for, in one of the four shapes (whether the person is in
  # the team is the plane's to refuse, at publish), whose it is, and a word back only with
  # a no. An allow must name an audience, the model's where it proposed one and the person
  # said nothing, and is refused where neither did: an artifact is published for somebody.
  defp check_answer(%{publication: publication}, decision, answer) do
    with :ok <- publication_keys(answer),
         {:ok, visibility} <- check_visibility(publication, decision, answer["visibility"]),
         {:ok, owner} <- check_owner(publication, decision, answer["owner"]),
         {:ok, reason} <- check_reason(decision, answer["reason"]) do
      {:ok,
       %{"visibility" => visibility, "owner" => owner, "reason" => reason}
       |> Map.reject(fn {_key, value} -> is_nil(value) end)
       |> with_aimed(publication, decision)}
    end
  end

  defp check_answer(_req, _decision, answer) when map_size(answer) == 0, do: {:ok, %{}}

  defp check_answer(req, _decision, answer) do
    if Map.keys(answer) -- ~w(visibility owner reason) == [],
      do:
        {:error,
         "visibility, owner and reason answer a publication, and this asks about #{req.tool}"},
      else:
        {:error, "agent, brief and reason answer a delegation, and this asks about #{req.tool}"}
  end

  defp publication_keys(answer) do
    case Map.keys(answer) -- ~w(visibility owner reason) do
      [] ->
        :ok

      keys ->
        {:error,
         "a publication's answer takes visibility, owner and reason, not #{Enum.join(keys, ", ")}"}
    end
  end

  @audiences "private, organisation, team:<name> or profile:<name>"

  defp check_visibility(_publication, :deny, _visibility), do: {:ok, nil}

  defp check_visibility(%{"visibility" => proposed}, _decision, nil) when is_binary(proposed),
    do: {:ok, proposed}

  defp check_visibility(_publication, _decision, nil),
    do: {:error, "say whom it is for: visibility is #{@audiences}"}

  defp check_visibility(_publication, _decision, visibility) do
    if audience?(visibility),
      do: {:ok, visibility},
      else: {:error, "visibility is #{@audiences}, not #{inspect(visibility)}"}
  end

  defp audience?(visibility) when visibility in ~w(private organisation), do: true
  defp audience?("team:" <> name), do: name != ""
  defp audience?("profile:" <> name), do: name != ""
  defp audience?(_other), do: false

  defp check_owner(_publication, :deny, _owner), do: {:ok, nil}

  # Whose an artifact is does not change with a version, so a republish takes no owner:
  # one given is dropped rather than sent for the plane to refuse.
  defp check_owner(%{"id" => id}, _decision, _owner) when is_binary(id), do: {:ok, nil}
  defp check_owner(publication, _decision, nil), do: {:ok, publication["owner"]}
  defp check_owner(_publication, _decision, owner) when owner in ~w(me team), do: {:ok, owner}

  defp check_owner(_publication, _decision, other),
    do: {:error, "owner is me or team, not #{inspect(other)}"}

  # Which of the audience and the owner the person changed from the model's proposal, an
  # audience chosen where the model proposed none among them: what the tool says it ran as.
  defp with_aimed(answer, _publication, :deny), do: answer

  defp with_aimed(answer, publication, _decision) do
    edited =
      for key <- ~w(visibility owner),
          Map.has_key?(answer, key),
          answer[key] != publication[key],
          do: key

    Map.put(answer, "edited", edited)
  end

  defp known_keys(answer) do
    case Map.keys(answer) -- ~w(agent brief reason) do
      [] ->
        :ok

      keys ->
        {:error,
         "a delegation's answer takes agent, brief and reason, not #{Enum.join(keys, ", ")}"}
    end
  end

  defp check_agent(_delegation, :deny, _agent), do: {:ok, nil}
  defp check_agent(delegation, _decision, nil), do: {:ok, delegation["agent"]}

  defp check_agent(delegation, _decision, agent) when is_binary(agent) do
    offered = for %{"name" => name} <- List.wrap(delegation["agents"]), do: name

    if agent in offered,
      do: {:ok, agent},
      else: {:error, "#{agent} is not a subagent this can go to: #{Enum.join(offered, ", ")}"}
  end

  defp check_agent(_delegation, _decision, other),
    do: {:error, "agent is a subagent's name, not #{inspect(other)}"}

  defp check_brief(_delegation, :deny, _brief), do: {:ok, nil}
  defp check_brief(_delegation, _decision, nil), do: {:ok, nil}

  defp check_brief(delegation, _decision, edits) do
    before = delegation["brief"] || %{}

    case Delegate.edit(before, edits) do
      {:ok, ^before} -> {:ok, nil}
      {:ok, brief} -> {:ok, brief}
      {:error, sentence} -> {:error, sentence}
    end
  end

  defp check_reason(:deny, reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:ok, nil}
      text -> {:ok, text}
    end
  end

  defp check_reason(_decision, nil), do: {:ok, nil}
  defp check_reason(:deny, other), do: {:error, "reason is a word back, not #{inspect(other)}"}
  defp check_reason(_decision, _reason), do: {:error, "a word back goes with a denial"}

  defp with_edited(%{"brief" => brief} = answer, before),
    do: Map.put(answer, "edited", Delegate.edited(before || %{}, brief))

  defp with_edited(answer, _before), do: answer

  # A second answer to a decided prompt is not an error — two people watching one
  # session is the normal case — so it is reported as an event and changes nothing.
  defp already_resolved(state, call_id) do
    case Map.fetch(state.resolved, call_id) do
      {:ok, %{agent_path: agent_path, by: by}} ->
        Log.append(state.session_id, agent_path, :approval_resolved, %{
          "call_id" => call_id,
          "resolved_by" => by
        })

        state

      :error ->
        state
    end
  end

  defp resolved_by(req, actor) do
    %{agent_path: req.agent_path, by: describe_actor(actor)}
  end

  defp describe_actor(nil), do: "system"
  defp describe_actor(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp describe_actor(%{subject: subject}) when is_binary(subject), do: subject
  defp describe_actor(_actor), do: "system"

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {gone, pending} =
      Enum.split_with(state.pending, fn {_id, entry} -> entry.monitor == monitor end)

    # The call that was asking has been closed off — timed out, cancelled — so nothing is
    # waiting for this answer any more, including a call from before the tree started.
    awaiting = Map.drop(state.awaiting, Enum.map(gone, &elem(&1, 0)))

    {:noreply, %{state | pending: Map.new(pending), awaiting: awaiting}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # The log is JSON, so the request crosses into it as plain data.
  defp describe(req) do
    %{
      "call_id" => req.call_id,
      "tool" => req.tool,
      "args" => req.args,
      "agent_path" => req.agent_path
    }
  end

  # The request as it is asked: a delegation's with what the gate shows (Decision 850), a
  # publication's with what the person aims, and one a per-tool rule asks with that rule
  # (#658), so the person sees why it asks.
  defp requested(%{delegation: delegation} = req),
    do: Map.put(describe(req), "delegation", delegation)

  defp requested(%{publication: publication} = req),
    do: req |> requested_rule() |> Map.put("publication", publication)

  defp requested(req), do: requested_rule(req)

  defp requested_rule(%{rule: rule} = req) when is_map(rule),
    do: Map.put(describe(req), "rule", rule)

  defp requested_rule(req), do: describe(req)

  # A request that must be asked (`always: true`), and a delegation a person asked to see,
  # stay for their answers.
  defp release_all(state) do
    {kept, released} =
      Enum.split_with(state.pending, fn {_id, entry} ->
        always?(entry.req) or delegation?(entry.req)
      end)

    Enum.each(released, fn {_id, entry} ->
      Process.demonitor(entry.monitor, [:flush])
      GenServer.reply(entry.from, reply(entry.req, :allow, %{}))
    end)

    %{state | pending: Map.new(kept)}
  end

  # A call the tool says must be asked about (Decision 823): neither `auto_approve` nor a
  # standing `allow_session` answers it, only a person, or `mode: :deny`'s no.
  defp always?(req), do: Map.get(req, :always, false) == true
end
