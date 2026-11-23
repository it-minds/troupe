defmodule Troupe.Remote.Translate do
  @moduledoc """
  Remote events, as local ones.

  The TUI's model is a fold over `Troupe.Event`s, and the point of the remote
  client is that a remote session looks like a local one on screen. So the
  translation happens here, once, at the edge: a worker's durable and ephemeral
  events become the same event types the local session emits, and only a handful
  of genuinely new types (`:tool_started`, `:remote_note`, `:remote_status`,
  `:input_accepted`, `:fs_changed`) had to be added to the model (Decision 75).

  An unknown event type is logged once per type and rendered generically, as the
  contract requires; the same goes for unknown fields, which are simply not read.
  """

  alias Troupe.Client.Message
  alias Troupe.Event
  alias Troupe.Protocol.Words

  require Logger

  # The two model errors that are about the key (`Troupe.UI.ModelError`).
  @key_errors ["no API key is configured", "the provider rejected the credentials"]
  @plane_key_step "the model's key is the plane's, not this machine's: ask the plane's administrator"

  # `agent_woken`: a root that had finished took the new input as its next turn.
  @woken "the agent had finished; new input picked the conversation back up"

  @typedoc """
  What the translator has to remember between events of one session, and what the
  window it opens says the session works in: `:remote` for a worker on a plane,
  `:shared` or `:worktree` for a session in the daemon on this machine. `profile` is the
  agent the session was started with, when the client knows it, which names the `root`
  window as it names every other: `troupe run build …` prints `spawned /build`, not
  `spawned /root`. `budget` is each budget question not yet answered: whether it is
  still asked, who asked, and what its `budget_ask_started` said. `me` is the subject this
  client is connected as, once `initialize` said it: a line another person sent is drawn
  with their name, and one of this person's own is not. `limits` is each window agent's
  budget ceilings by dimension, as its `budget_warning`s and `budget_ask_started`s said
  them, and `stopped` how each one ended that the harness wakes no more (its reason, and
  the limit a spent budget names): what a dropped input is said with.
  """
  @type memory :: %{
          agents: MapSet.t(),
          unknown: MapSet.t(),
          isolation: atom(),
          profile: String.t() | nil,
          budget: %{String.t() => {:asked | :ended, String.t(), map()}},
          me: String.t() | nil,
          limits: %{String.t() => %{String.t() => number()}},
          stopped: %{String.t() => {String.t(), String.t() | nil}}
        }

  @spec memory(atom(), String.t() | nil) :: memory()
  def memory(isolation \\ :remote, profile \\ nil),
    do: %{
      agents: MapSet.new(),
      unknown: MapSet.new(),
      isolation: isolation,
      profile: profile,
      budget: %{},
      me: nil,
      limits: %{},
      stopped: %{}
    }

  @doc "Records the subject this client is connected as, from `initialize`'s principal."
  @spec me(memory(), String.t() | nil) :: memory()
  def me(memory, subject) when is_binary(subject) and subject != "", do: %{memory | me: subject}
  def me(memory, _subject), do: memory

  @doc """
  One durable event as zero or more local events, plus the memory to carry on
  with. The first event for an agent is preceded by the `branch_spawned` the
  model needs before it has a window to fold into.
  """
  @spec durable(String.t(), map(), memory()) :: {[Event.t()], memory()}
  def durable(session_id, %{} = event, memory) do
    agent = agent_path(event)
    {spawned, memory} = ensure_branch(session_id, agent, event, memory)
    {events, memory} = translate(session_id, agent, event, memory)
    {spawned ++ events, memory}
  end

  @doc "An ephemeral event (`llm_delta`, `agent_state`, `progress`, `presence`) as a transient local event."
  @spec ephemeral(String.t(), map(), memory()) :: {[Event.t()], memory()}
  def ephemeral(session_id, %{} = event, memory) do
    agent = agent_path(event)
    data = data(event)

    case event["type"] do
      "llm_delta" ->
        reasoning? = Map.get(data, "reasoning") == true or data["kind"] in ["reasoning", "thinking"]
        text = %{text: text_of(data)}
        text = if reasoning?, do: Map.put(text, :reasoning, true), else: text
        {[transient(session_id, agent, :llm_delta, text)], memory}

      # The worker's own word on what an agent is doing, as it changes.
      "agent_state" ->
        {[transient(session_id, agent, :agent_state, %{to: state_atom(data["state"] || "idle")})],
         memory}

      "progress" ->
        {[
           transient(session_id, agent, :agent_state, %{to: state_atom(data["state"] || "working")})
         ], memory}

      # The person's own command while it runs (root Decision 813), drawn as it streams;
      # its end is the durable `user_shell`.
      "shell_started" ->
        {[
           transient(session_id, agent, :shell_started, %{
             run_id: data["run_id"],
             command: to_string(data["command"] || ""),
             agent: data["agent"] != false,
             where: where(memory)
           })
         ], memory}

      "shell_output" ->
        {[
           transient(session_id, agent, :shell_output, %{
             run_id: data["run_id"],
             text: to_string(data["text"] || "")
           })
         ], memory}

      # Watch went on or off, whoever turned it (root Decision 844): the status line follows.
      "watch_changed" ->
        backend = if data["enabled"] == true, do: data["backend"]

        {[
           transient(session_id, agent, :watch_changed, %{
             enabled: data["enabled"] == true,
             backend: backend
           })
         ], memory}

      # Watch fell back to polling, or could not start: the line under the screen.
      "watch_notice" ->
        {[transient(session_id, agent, :notice, %{text: to_string(data["message"] || "")})], memory}

      # Who joined and who left, and from where (root #58): `via` is `plane` for somebody
      # steering a laptop's session from another device.
      "presence" ->
        {[
           transient(session_id, agent, :presence, %{
             subject: data["subject"],
             name: data["display_name"] || data["subject"],
             state: data["state"],
             via: data["via"]
           })
         ], memory}

      "summary_diff" ->
        {[], memory}

      other ->
        {[], note_unknown(other, memory)}
    end
  end

  @doc "The agent an event names, as this client spells a path: `root/explore#1`."
  @spec agent_of(map()) :: String.t() | nil
  def agent_of(%{"agent" => agent}) when is_binary(agent) and agent != "", do: agent
  def agent_of(%{"agent" => [_ | _] = path}), do: Enum.map_join(path, "/", &to_string/1)
  def agent_of(_event), do: nil

  @doc "The window a durable event belongs to: the root of its agent path."
  @spec root_of(map()) :: String.t()
  def root_of(event), do: event |> agent_path() |> root()

  @doc "Records an agent root as already having a window, so it is not opened twice."
  @spec remember(memory(), String.t()) :: memory()
  def remember(memory, root), do: %{memory | agents: MapSet.put(memory.agents, root)}

  @doc "The `seq` of a durable event, or nil."
  @spec seq(map()) :: non_neg_integer() | nil
  def seq(%{"seq" => seq}) when is_integer(seq), do: seq
  def seq(_event), do: nil

  @doc "The `command_id` a durable event was caused by, if any — on the event or in its data."
  @spec command_id(map()) :: String.t() | nil
  def command_id(%{"command_id" => id}) when is_binary(id), do: id
  def command_id(%{"data" => %{"command_id" => id}}) when is_binary(id), do: id
  def command_id(_event), do: nil

  ## Internals

  # The worker writes the path as a list from the root (`["root", "explore#1"]`); the
  # contract's example and the fake write one string. Either becomes `root/explore#1`.
  # A fork's first event names no agent; it is the session's own, whose window is `root`,
  # not a second one beside it.
  defp agent_path(%{"type" => "session_forked"} = event), do: agent_of(event) || "root"
  defp agent_path(event), do: agent_of(event) || "session-1"

  # `actor` is `{"kind", "subject", "display_name"}` on the wire; a name is what a
  # transcript shows.
  defp actor_of(%{"actor" => %{} = actor}),
    do: actor["display_name"] || actor["subject"] || actor["kind"]

  defp actor_of(%{"actor" => actor}) when is_binary(actor), do: actor
  defp actor_of(_event), do: nil

  # `by`, on a line another person sent: their name where the actor carries one worth
  # showing, their subject where not. Nothing on this person's own, nor while this client
  # does not yet know who it is, so a line is never drawn as somebody else's by mistake.
  defp put_by(data, %{"actor" => %{"kind" => "user", "subject" => subject} = actor}, %{me: me})
       when is_binary(me) and is_binary(subject) and subject != me do
    name = actor["display_name"]

    Map.put(
      data,
      :by,
      if(is_binary(name) and String.trim(name) not in ["", subject],
        do: String.trim(name),
        else: subject
      )
    )
  end

  defp put_by(data, _event, _memory), do: data

  # A person's answer: `by` by name where the actor carries one worth showing, else the
  # subject, and `mine?` the person here. Nothing for the harness's own, nor while this
  # client does not yet know who it is, so an answer is never drawn as another's by mistake.
  defp answered_by(%{"actor" => %{"kind" => "user", "subject" => subject} = actor}, %{me: me})
       when is_binary(me) and is_binary(subject) and subject != "" do
    name = actor["display_name"]

    %{
      by:
        if(is_binary(name) and String.trim(name) not in ["", subject],
          do: String.trim(name),
          else: subject
        ),
      by_subject: subject,
      mine?: me == subject
    }
  end

  defp answered_by(_event, _memory), do: %{}

  defp data(%{"data" => %{} = data}), do: data
  defp data(_event), do: %{}

  defp ts(%{"ts" => ts}) when is_integer(ts), do: ts

  defp ts(%{"ts" => ts}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp ts(_event), do: System.system_time(:millisecond)

  # The model needs a window before anything can be folded into it, and a remote
  # session has no `branch_spawned` of its own: the first event mentioning an
  # agent opens its window.
  defp ensure_branch(session_id, agent, event, memory) do
    root = root(agent)

    if MapSet.member?(memory.agents, root) do
      {[], memory}
    else
      spawned =
        durable_event(session_id, root, :branch_spawned, ts(event), %{
          name: profile_name(root, memory),
          isolation: memory.isolation,
          prompt: ""
        })

      {[spawned], %{memory | agents: MapSet.put(memory.agents, root)}}
    end
  end

  defp root(path), do: path |> String.split("/") |> hd()

  # A worker on a plane asks the model with the plane's key, which nothing on this
  # machine sets: under a key error the next step is the plane's administrator, where a
  # session on this machine gets `troupe config` (`Troupe.UI.ModelError`).
  defp llm_error(message, :remote) do
    if String.starts_with?(message, @key_errors),
      do: %{message: message, next_step: @plane_key_step},
      else: %{message: message}
  end

  defp llm_error(message, _isolation), do: %{message: message}

  # The session's own agent is `root` on the wire whatever it is, and is named for the
  # profile it was started with, as `Troupe.Remote.Worker` names the window it opens
  # before any event. `code-3` is the third branch of the `code` profile, the same
  # spelling a local session uses; a name with no suffix stands for itself.
  defp profile_name("root", %{profile: profile}) when is_binary(profile) and profile != "",
    do: profile

  defp profile_name(root, _memory) do
    case Regex.run(~r/^(.*)-\d+$/, root) do
      [_, name] -> name
      _ -> root
    end
  end

  defp translate(session_id, agent, event, memory) do
    type = event["type"]
    data = data(event)
    at = ts(event)
    cid = command_id(event)
    seq = seq(event)
    emit = &durable_event(session_id, agent, &1, at, &2, seq)

    # Two facts the clauses below need in guards: the budget question (troupe-remote
    # Decision 660) rides on the question path under a `budget-<n>` id and has an event
    # of its own beside it, and a `user_input` from the harness is a note, not something
    # anybody typed.
    budget_question? = match?("budget-" <> _, call_id(data))
    harness_note? = data["source"] == "harness"
    shell_note? = data["source"] == "shell"
    subagent_end? = data["source"] == "subagent"

    # The worker's vocabulary (`llm_response`, `tool_call_started` — PROTOCOL.md §4),
    # under the protocol schema's names and no others.
    case type do
      # The note the harness gives a model whose reply was cut or empty (troupe-remote
      # Decision 659): shown as what it is rather than as the person's words.
      "user_input" when harness_note? ->
        {[emit.(:remote_note, %{text: "harness: " <> text_of(data)})], memory}

      # What the agent was given of the person's own commands (root Decision 813): each is
      # on screen already as its `user_shell`, the person's command and what it printed.
      "user_input" when shell_note? ->
        {[], memory}

      # The end of a child the agent started in the background, handed to it once (root
      # Decision 853): a line saying whose and how it ended, not the person's words. The
      # report itself is the child's own `agent_done`.
      "user_input" when subagent_end? ->
        {[emit.(:remote_note, %{text: subagent_end(data)})], memory}

      "user_shell" ->
        {[emit.(:user_shell, user_shell(data, memory))], memory}

      # A line sent while the agent works comes back twice, queued and then taken, and both
      # copies name the send's command id; the window draws it once.
      type when type in ["input_queued", "user_input"] ->
        {[
           emit.(
             :input,
             put_by(
               %{
                 content: text_of(data),
                 source: source_atom(data["source"]),
                 command_id: cid,
                 actor: actor_of(event),
                 queued: type != "user_input"
               },
               event,
               memory
             )
           )
         ], memory}

      "input_accepted" ->
        {[emit.(:input_accepted, %{command_id: cid})], memory}

      "llm_response" ->
        {[emit.(:assistant_message, message(data))], memory}

      # The request carries the model it went to, which the window names when nothing
      # comes back from it.
      "llm_request" ->
        {[emit.(:agent_state, %{to: :thinking, model: data["model"]})], memory}

      # Its own event rather than a note, so the status line can say the model failed
      # instead of spinning on "starting" — which is all an idle agent looked like.
      "llm_error" ->
        {[
           emit.(:llm_error, llm_error(data["reason"] || "the model call failed", memory.isolation))
         ], memory}

      "tool_call_started" ->
        {[
           emit.(:tool_started, %{
             call_id: call_id(data),
             name: data["name"] || "tool",
             input: input(data)
           })
         ], memory}

      "tool_call_completed" ->
        {[emit.(:tool_call_completed, completed(data))], memory}

      # What the prompt was read from (`instructions_loaded`) is `/context`'s to show, not a
      # line in the transcript at every turn the files changed.
      type
      when type in [
             "tool_results",
             "mounts_resolved",
             "config_upgraded_ack",
             "instructions_loaded"
           ] ->
        {[], memory}

      # A delegation a person asked to see first carries what the gate shows, as the daemon
      # wrote it: the agent, its definition, the brief, the tools, the budget and the depth,
      # and the subagents it could go to instead.
      "approval_requested" ->
        {[
           emit.(:approval_requested, %{
             call_id: call_id(data),
             name: data["name"] || data["tool"] || "tool",
             preview: preview(data),
             delegation: if(is_map(data["delegation"]), do: data["delegation"]),
             # An agent's publication, for the person to say whom it is for: its title,
             # kind, how many files, whom the agent proposed it for and whose, its note.
             publication: if(is_map(data["publication"]), do: data["publication"]),
             # The per-tool rule of the configuration that asked, when one did (root #658).
             rule: if(is_map(data["rule"]), do: data["rule"])
           })
         ], memory}

      "approval_decided" ->
        {[emit.(:approval_answered, %{call_id: call_id(data), decision: decision(data)})], memory}

      # `ask_user` (troupe-remote Decision 651): the agent hands a decision to the person
      # at the screen, with options a client may draw as a menu.
      # The window knows the budget question as a `:budget` item, and the question the
      # harness also wrote fills it in: its words, and the options a person picks by digit
      # or types back (Decision 120). Either event may come first for a client that
      # subscribed between them, so each merges into what the other left and draws the
      # item again, and the window replaces it by id. A cancel ends it, but it is still
      # owed: the next turn's gate asks it again under the same id, with a
      # `question_asked` alone, and that one draws the item again as it was.
      "question_asked" when budget_question? ->
        budget_asked(
          emit,
          agent,
          call_id(data),
          %{question: to_string(data["question"] || ""), options: options(data)},
          memory
        )

      "question_answered" when budget_question? ->
        {[], memory}

      "budget_ask_started" ->
        budget_asked(
          emit,
          agent,
          call_id(data),
          %{detail: data["detail"] || "budget exhausted", dimension: dimension(data["dimension"])},
          ceiling(memory, agent, data)
        )

      "budget_ask_answered" ->
        {[emit.(:budget_ask_answered, %{call_id: call_id(data), decision: data["decision"]})],
         %{memory | budget: Map.delete(memory.budget, call_id(data))}}

      # The failure guard's question (troupe-remote Decision 687) is drawn as the question it
      # rides on, the other way round from the budget's: its options are the harness's own
      # words, `stop` first, and headless mode answers any question with the first option.
      # The tool and the count this adds are already the question's text.
      "tool_failures_ask_started" ->
        {[], memory}

      # Ends the question as its answer does. It is the only word there is when the session
      # has nobody to ask: the question is written, never answered, and the agent stops.
      "tool_failures_ask_answered" ->
        {[
           emit.(:tool_failures_ask_answered, %{
             call_id: call_id(data),
             decision: data["decision"]
           })
         ], memory}

      # A reply the output cap cut, or one with nothing in it (troupe-remote Decision 659).
      "truncated" ->
        {[emit.(:remote_note, %{text: truncated(data)})], memory}

      # `preview` is what the question is about, drawn as it is under it: the prompt a
      # workspace's command would send (troupe Decision 814).
      "question_asked" ->
        {[
           emit.(:question_asked, %{
             call_id: call_id(data),
             question: to_string(data["question"] || ""),
             options: options(data),
             multiple: data["multiple"] == true,
             preview: if(is_binary(data["preview"]), do: data["preview"])
           })
         ], memory}

      # Who answered is the event's actor: `by` their name, or their
      # subject, and `mine?` the person here, for a window several people steer.
      "question_answered" ->
        {[
           emit.(
             :question_answered,
             Map.merge(
               %{call_id: call_id(data), text: to_string(data["text"] || "")},
               answered_by(event, memory)
             )
           )
         ], memory}

      # A workspace's command that asked first and was not sent: the harness's sentence
      # says how to run it later (troupe Decision 814).
      "command_declined" ->
        {[emit.(:remote_note, %{text: to_string(data["reason"] || "the command was not sent")})],
         memory}

      # What `troupe onboard`, or the librarian, would do in this workspace, said once at a
      # start (troupe Decision 827): the harness's own sentence, as a line.
      "onboarding_suggested" ->
        {[emit.(:remote_note, %{text: to_string(data["message"] || "run troupe onboard here")})],
         memory}

      # Something the configuration did to the session, said once (troupe issue #644: an
      # organisation's output ceiling shortened the thinking): the harness's sentence.
      "config_note" ->
        {[emit.(:remote_note, %{text: to_string(data["message"] || "a setting was held")})], memory}

      # The organisation's memory changed while the session ran (root issue #55): a save on
      # the plane reached it, and this turn read the new versions. The harness's sentence.
      "memory_changed" ->
        {[
           emit.(:remote_note, %{
             text: to_string(data["message"] || "the organisation's memory changed")
           })
         ], memory}

      # Somebody wrote a comment on an artifact this session published (root #62): one line,
      # who, on which and what, for whoever steers the session to act on. Never input.
      "artifact_commented" ->
        {[emit.(:remote_note, %{text: commented(data)})], memory}

      # The session given to its team by its owner, or taken back (root #1169): a line; the
      # worker moves the status line's mark.
      "session_visibility_changed" ->
        {[emit.(:remote_note, %{text: visibility_changed(data)})], memory}

      # A saved `AI!` or `AI?` comment started a branch of this session (root Decision 844):
      # the branch's session, its agent, and the comments, as the daemon wrote them.
      "watch_triggered" ->
        {[
           emit.(:watch_triggered, %{
             session_id: data["session_id"],
             agent: to_string(data["agent"] || "quick"),
             mode: data["mode"],
             markers: List.wrap(data["markers"]),
             error: data["error"]
           })
         ], memory}

      # The agent and skill files a start found and did not read (root Decision 826): on a
      # pod, a working copy's that the bundle's or a built-in's name beats; in a worktree,
      # one the main checkout has not committed.
      "files_skipped" ->
        {[emit.(:remote_note, %{text: files_skipped(data["files"])})], memory}

      # A wake past what the agent could not read (`session.repair`): the event stays in the
      # log, and every replay from here skips it.
      "log_repaired" ->
        {[emit.(:remote_note, %{text: repaired(data["at"])})], memory}

      "approval_resolved" ->
        {[], memory}

      "todo_updated" ->
        {[emit.(:todo_updated, %{items: todos(data)})], memory}

      # What the window runs is named by the agent itself, whatever the window is called
      # (TUI Decision 156).
      "agent_started" ->
        {[
           emit.(:remote_note, %{text: "agent started" <> as(data)}),
           emit.(:agent_named, %{name: data["profile"]})
         ], unstop(memory, agent)}

      "agent_restarted" ->
        {[emit.(:remote_note, %{text: "agent restarted"})], memory}

      # A finished root agent took new input as a turn: the window is working again, and
      # says the conversation was picked back up. Only a finish is woken so.
      "agent_woken" ->
        {[emit.(:remote_note, %{text: @woken}), emit.(:agent_state, %{to: :thinking})],
         unstop(memory, agent)}

      # The reason rides along, so a reader that must tell a finish from a stop short (the
      # headless printer's exit code) does not have to parse the note. The note comes
      # first: a headless run ends at the state, and would end without the summary. A
      # window's agent that ended so the harness drops its input says why, after it, for
      # its input line.
      "agent_done" ->
        {stopped, memory} = done_stop(emit, agent, data, memory)

        {done_note(emit, data) ++
           [emit.(:agent_state, spent(%{to: :done, reason: data["reason"]}, data))] ++ stopped,
         memory}

      # The turn is over and the agent waits for input: the same `idle` the live
      # `agent_state` says, but from the log, so it is neither dropped nor missed by a
      # client that attached after it happened. A `reason` rides along when the harness
      # ended the turn rather than the model (`tool_failures`, troupe-remote Decision 687;
      # `agent_failed`, with its `detail`, Decision 727), and so does what the turn cost
      # (root Decision 769), on each of the three events that end one.
      "turn_ended" ->
        {[emit.(:agent_state, %{to: :idle} |> ended_by(data) |> spent(data))], memory}

      # The model's own `:cancelled`, not a note that says so: it also ends whatever the
      # agent and those under it were still asking, which a subagent the cancel took down
      # never answers (#145).
      "cancelled" ->
        {[
           emit.(:cancelled, %{}),
           emit.(:agent_state, spent(%{to: :idle, reason: "cancelled"}, data))
         ], budget_cancelled(memory, agent)}

      # The summariser's call is the session's to pay for as a reply's is (root Decision
      # 769), so what it used reaches the window's count.
      "compacted" ->
        {[emit.(:remote_note, %{text: compacted_note(data)})] ++ summarised(emit, data), memory}

      # The limit, where the `agent_done` before it did not name it, goes to the input line.
      "budget_exhausted" ->
        {named, memory} = exhausted_limit(emit, agent, data, memory)
        {[emit.(:remote_note, %{text: "budget exhausted" <> limit(data)})] ++ named, memory}

      # Input a done agent did not take: dropped, and said so with why and what to do.
      # Never the picked-up line, which is `agent_woken`'s.
      "input_after_done" ->
        {[emit.(:remote_note, %{text: not_taken(memory, agent)})], memory}

      # A limit is near: durable on the wire, shown once by the window, which already knew
      # how. Its ceiling is kept, to name a spent limit with its size.
      "budget_warning" ->
        memory = ceiling(memory, agent, data)

        {[
           emit.(:budget_warning, %{
             dimension: dimension(data["dimension"]),
             used: data["used"],
             limit: data["limit"],
             fraction: data["fraction"],
             detail: data["detail"] || to_string(data["dimension"])
           })
         ], memory}

      # The transcript says when the rules changed and what they took away or gave (root
      # Decision 841); the window's header follows the agent it runs now (TUI Decision 156).
      "profile_switched" ->
        {[
           emit.(:remote_note, %{text: "profile switched" <> switch(data) <> tools_changed(data)}),
           emit.(:agent_named, %{name: data["to"]})
         ], memory}

      # The session's goal (issue #59): its own events, because the window keeps it and the
      # status line shows it for as long as it is set, not only when it is announced.
      "goal_set" ->
        {[emit.(:goal_set, %{text: to_string(data["text"] || "")})], memory}

      "goal_cleared" ->
        {[emit.(:goal_cleared, %{})], memory}

      # A loop towards the goal (issue #59): its own events, because the window keeps where
      # it is and the status line shows it while it runs.
      "loop_started" ->
        {[
           emit.(:loop_started, %{loop_id: data["loop_id"], max_iterations: data["max_iterations"]})
         ], memory}

      "loop_iteration_started" ->
        {[emit.(:loop_iteration, %{loop_id: data["loop_id"], iteration: data["iteration"]})],
         memory}

      "loop_iteration_finished" ->
        {[
           emit.(:loop_iteration_finished, %{
             iteration: data["iteration"],
             outcome: to_string(data["outcome"]),
             detail: data["detail"]
           })
         ], memory}

      "loop_stopped" ->
        {[
           emit.(:loop_stopped, %{
             reason: to_string(data["reason"]),
             iterations: data["iterations"] || 0,
             detail: data["detail"],
             summary: data["summary"]
           })
         ], memory}

      # One in the background (root Decision 853) says so: its call answers at once, and the
      # child goes on working after it.
      "delegation_started" ->
        background = if data["wait"] == false, do: ", in the background", else: ""
        {[emit.(:remote_note, %{text: "delegated" <> to_child(data) <> background})], memory}

      "session_created" ->
        {[
           emit.(:remote_note, %{text: "session created" <> as(data)}),
           emit.(:agent_named, %{name: data["profile"]})
         ], memory}

      "trigger_fired" = type ->
        {[emit.(:remote_note, %{text: generic(type, data)})], memory}

      "session_activated" ->
        {[
           emit.(:remote_note, %{text: "session woke on the platform"}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      "session_resumed" ->
        {[
           emit.(:remote_note, %{text: "session resumed" <> moved(data)}),
           emit.(:remote_status, %{state: :active})
         ], memory}

      "session_dormant" ->
        {[
           emit.(:remote_note, %{text: "session went to sleep"}),
           emit.(:remote_status, %{state: :dormant})
         ], memory}

      "config_upgraded" ->
        {[emit.(:remote_note, %{text: "config upgraded" <> version(data)})], memory}

      "fs_changed" ->
        {[emit.(:fs_changed, %{paths: paths(data)})], memory}

      # A file the agent made for the person (`write_file` with `deliverable`, root issue
      # #765): on this machine where it is; on a pod, the command that saves it here.
      "file_ready" ->
        {[emit.(:remote_note, %{text: file_ready(data)})], memory}

      # A document `show` put on the session's scratchpad (root Decision 870): a card where
      # the call was, and a row of `/scratch` (TUI Decision 159).
      "scratch_updated" ->
        {[emit.(:scratch_updated, scratch(data))], memory}

      "session_tainted" ->
        {[emit.(:remote_note, %{text: tainted(data)})], memory}

      # Written beside the taint each time somebody's tools are offered, and when their
      # connection takes them away: whose they are and which, as a sentence.
      "tools_registered" ->
        {[emit.(:remote_note, %{text: registered(actor_of(event), data)})], memory}

      "tools_unregistered" ->
        {[emit.(:remote_note, %{text: unregistered(owner_of(event, data), data)})], memory}

      other when is_binary(other) ->
        {[emit.(:remote_note, %{text: generic(other, data)})], note_unknown(other, memory)}

      _ ->
        {[], memory}
    end
  end

  # The item as the window draws it, from whichever of its two events have come: the
  # harness's own says which limit, and the question it rides on says the words and the
  # options. Each draws it again with what it adds, and so does the question asked again
  # after a cancel ended it; the window keeps one item per id.
  defp budget_asked(emit, agent, id, fields, memory) do
    known =
      case memory.budget do
        %{^id => {_state, _agent, started}} -> started
        _ -> %{call_id: id, detail: "budget exhausted", dimension: nil, question: "", options: []}
      end

    started = Map.merge(known, fields)
    {[emit.(:budget_ask_started, started)], put_in(memory, [:budget, id], {:asked, agent, started})}
  end

  # The model's own rule for what a cancel ends: the agent it reached and every one under it.
  defp budget_cancelled(memory, path) do
    ended =
      Map.new(memory.budget, fn {id, {state, agent, started}} ->
        if agent == path or String.starts_with?(agent, path <> "/"),
          do: {id, {:ended, agent, started}},
          else: {id, {state, agent, started}}
      end)

    %{memory | budget: ended}
  end

  # Logged once per type, then rendered like any other note: an unknown event is
  # a server that is ahead of this client, not an error.
  defp note_unknown(type, memory) when is_binary(type) do
    if MapSet.member?(memory.unknown, type) do
      memory
    else
      Logger.info("troupe remote: rendering unknown event type #{type} generically")
      %{memory | unknown: MapSet.put(memory.unknown, type)}
    end
  end

  defp note_unknown(_type, memory), do: memory

  defp generic(type, data) when map_size(data) == 0, do: type

  defp generic(type, data) do
    summary =
      data
      |> Enum.map(fn {k, v} -> "#{k}=#{scalar(v)}" end)
      |> Enum.sort()
      |> Enum.take(4)
      |> Enum.join(" ")

    String.trim("#{type} #{summary}")
  end

  defp scalar(v) when is_binary(v), do: String.slice(v, 0, 60)
  defp scalar(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar(v) when is_list(v), do: "[#{length(v)}]"
  defp scalar(v) when is_map(v), do: "{#{map_size(v)}}"
  defp scalar(v), do: inspect(v)

  # `llm_response` carries the whole assistant message — `{"role", "content": [blocks]}`
  # — where the dotted vocabulary carried its text. Its text is kept, and its reasoning,
  # which the log keeps as a block of its own, so that a replayed or late-attached
  # session, which saw none of it stream, draws its reasoning frame from it. The tool
  # calls in it arrive again as `tool_call_started`/`tool_call_completed`, which is what
  # the model draws a tool line from, and keeping both drew every call twice.
  defp message(data) do
    content =
      case data do
        %{"message" => %{"content" => blocks}} when is_list(blocks) ->
          case Enum.flat_map(blocks, &block/1) do
            [] -> [Message.text_block("")]
            kept -> kept
          end

        _ ->
          [Message.text_block(text_of(data))]
      end

    %{content: content, usage: usage(data["usage"]), model: data["model"]}
  end

  defp block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [Message.text_block(text)]

  # A redacted block has no words to show, and an empty one nothing to draw.
  defp block(%{"type" => type, "text" => text} = b)
       when type in ["reasoning", "thinking"] and is_binary(text) do
    if Map.get(b, "redacted") == true or String.trim(text) == "",
      do: [],
      else: [Message.reasoning_block(text)]
  end

  defp block(_block), do: []

  defp source_atom("watch"), do: :watch
  defp source_atom("loop"), do: :loop
  defp source_atom(_source), do: :user

  # A child in the background its parent ended (root Decision 853) says how in a line; what it
  # had done is its parent's to read, as the end it was handed.
  defp done_note(emit, %{"reason" => reason}) when reason in ~w(stopped cancelled failed),
    do: [emit.(:remote_note, %{text: ended_by_parent(reason)})]

  # A finish in parts is said from its report, its changed line in this client's words: the
  # summary beside it says that line for the agent that delegated, ending on the
  # `read_branch` call that reads the diff, which a person cannot make.
  defp done_note(emit, %{"report" => %{"summary" => summary, "ran" => _} = report})
       when is_binary(summary),
       do: [emit.(:remote_note, %{text: "done: " <> reported(report)})]

  defp done_note(emit, %{"summary" => summary}) when is_binary(summary) and summary != "",
    do: [emit.(:remote_note, %{text: "done: " <> summary})]

  defp done_note(emit, %{"reason" => reason})
       when is_binary(reason) and reason not in ["finished", "done"],
       do: [emit.(:remote_note, %{text: "done (#{reason})"})]

  defp done_note(_emit, _data), do: []

  # The summary, then each part under its name, `changed` first and on its own line.
  defp reported(report) do
    parts =
      ["changed: " <> changed_line(report["changed"])] ++
        for part <- ~w(ran passed unverified needs), is_binary(report[part]) do
          if String.contains?(report[part], "\n"),
            do: "#{part}:\n#{report[part]}",
            else: "#{part}: #{report[part]}"
        end

    Enum.join([report["summary"], Enum.join(parts, "\n")], "\n\n")
  end

  # The files the line names before it says how many more there are, as the harness's own.
  @listed 20

  # What the agent's file tools changed, as Troupe counted it: the files and the lines, and
  # under it each file, the commands not counted and what the agent said besides.
  defp changed_line(%{"files" => files} = changed) when is_list(files) do
    commands = if is_integer(changed["commands"]), do: changed["commands"], else: 0

    head =
      cond do
        files != [] ->
          "#{Words.count(length(files), "file")}, +#{changed["added"] || 0} -#{changed["removed"] || 0}"

        commands > 0 ->
          "no file through its file tools"

        true ->
          "nothing"
      end

    shown =
      for %{"path" => path} = file <- Enum.take(files, @listed) do
        "#{path} +#{file["added"] || 0} -#{file["removed"] || 0}" <>
          if(file["whole"] == true, do: " (written whole)", else: "")
      end

    under =
      shown ++
        if(length(files) > @listed, do: ["and #{length(files) - @listed} more"], else: []) ++
        if(commands > 0,
          do: ["not counted: what its #{Words.count(commands, "command")} changed"],
          else: []
        ) ++
        if(is_binary(changed["said"]), do: ["it says: " <> changed["said"]], else: [])

    Enum.join([head | Enum.map(under, &("  " <> &1))], "\n")
  end

  defp changed_line(_changed), do: "not reported"

  # How a window's agent ended that the harness wakes no more: every end but `finished`
  # (new input resumes it) and `llm_error` (a root rests on one, and the next message is a
  # retry). What is sent to one of these is dropped, with `input_after_done`.
  @stops %{
    "refused" => "the model refused to go on",
    "output_truncated" => "the model's reply was cut off at its length limit",
    "empty_reply" => "the model's reply came back empty",
    "tool_failures" => "a tool kept failing"
  }

  defp done_stop(emit, agent, %{"reason" => reason} = data, memory)
       when is_binary(reason) and reason not in ["finished", "llm_error"] do
    if agent == root(agent) do
      limit = if is_binary(data["limit"]), do: data["limit"]
      memory = put_in(memory, [:stopped, agent], {reason, limit})
      {[emit.(:stopped, %{why: stopped_because(memory, agent)})], memory}
    else
      {[], memory}
    end
  end

  defp done_stop(_emit, agent, _data, memory), do: {[], unstop(memory, agent)}

  defp unstop(memory, agent), do: %{memory | stopped: Map.delete(memory.stopped, agent)}

  # A spent budget's `agent_done` from a harness that did not name the limit on it.
  defp exhausted_limit(emit, agent, %{"limit" => limit}, memory) when is_binary(limit) do
    case memory.stopped do
      %{^agent => {"budget_exhausted", nil}} ->
        memory = put_in(memory, [:stopped, agent], {"budget_exhausted", limit})
        {[emit.(:stopped, %{why: stopped_because(memory, agent)})], memory}

      _ ->
        {[], memory}
    end
  end

  defp exhausted_limit(_emit, _agent, _data, memory), do: {[], memory}

  # A ceiling a `budget_warning` or `budget_ask_started` says, for naming a spent limit
  # with its size.
  defp ceiling(memory, agent, %{"dimension" => dim, "limit" => n})
       when is_binary(dim) and is_number(n) and n > 0 do
    case limit_dimension(dim) do
      nil -> memory
      d -> %{memory | limits: Map.update(memory.limits, agent, %{d => n}, &Map.put(&1, d, n))}
    end
  end

  defp ceiling(memory, _agent, _data), do: memory

  @limit_dimensions %{
    "max_turns" => "turns",
    "turns" => "turns",
    "max_input_tokens" => "input",
    "input" => "input",
    "max_output_tokens" => "output",
    "output" => "output",
    "wall_clock" => "wall",
    "wall" => "wall"
  }
  defp limit_dimension(name), do: Map.get(@limit_dimensions, name)

  # Why the agent takes no more input, as the clause after "stopped:".
  defp stopped_because(memory, agent) do
    case Map.get(memory.stopped, agent) do
      {"budget_exhausted", limit} ->
        limit_words(limit, Map.get(memory.limits, agent, %{})) <> " is spent"

      {reason, _limit} ->
        Map.get(@stops, reason, "it ended " <> String.replace(reason, "_", " "))

      nil ->
        nil
    end
  end

  @doc """
  A spent budget limit in words, with its size where the session said it: "its 30-minute
  working limit", "its 40-turn limit", "its 6M input-token limit"; "its budget" for a
  limit this client does not know.
  """
  @spec limit_words(String.t() | nil, map()) :: String.t()
  def limit_words(limit, limits) do
    dim = limit && limit_dimension(limit)
    n = dim && Map.get(limits, dim)

    case {dim, n} do
      {"wall", n} when is_number(n) -> "its #{Words.duration(n, :adjective)} working limit"
      {"wall", _} -> "its working-time limit"
      {"turns", n} when is_number(n) -> "its #{n}-turn limit"
      {"turns", _} -> "its turn limit"
      {"input", n} when is_number(n) -> "its #{token_count(n)} input-token limit"
      {"input", _} -> "its input-token limit"
      {"output", n} when is_number(n) -> "its #{token_count(n)} output-token limit"
      {"output", _} -> "its output-token limit"
      _ -> "its budget"
    end
  end

  defp token_count(n) when n >= 1_000_000, do: one_place(n / 1_000_000) <> "M"
  defp token_count(n) when n >= 1_000, do: one_place(n / 1_000) <> "k"
  defp token_count(n), do: to_string(n)

  defp one_place(x) do
    rounded = Float.round(x * 1.0, 1)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  # `input_after_done`: the message was dropped, why, and what to do instead.
  defp not_taken(memory, agent) do
    why =
      case stopped_because(memory, root(agent)) do
        nil -> ""
        clause -> " (#{clause})"
      end

    "Your message was not taken: the session had stopped#{why}. Start a new session to continue."
  end

  defp ended_by_parent("stopped"), do: "stopped by its parent"
  defp ended_by_parent("cancelled"), do: "stopped by the cancel"
  defp ended_by_parent(_failed), do: "failed past its restarts"

  defp subagent_end(data) do
    child =
      case data["child_path"] do
        [_ | _] = path -> Enum.join(path, "/")
        _ -> "a subagent"
      end

    how =
      case data["ended"] do
        "finished" -> "finished"
        "stopped" -> "stopped by its parent"
        "cancelled" -> "stopped by the cancel"
        "interrupted" -> "stopped by a restart"
        "failed" -> "failed past its restarts"
        _ -> "ended before it finished"
      end

    "#{child}, in the background: #{how}; its end reached its parent"
  end

  # With what it raised when the agent kept crashing (`agent_failed`, Decision 727).
  defp ended_by(idle, %{"reason" => reason} = data) when is_binary(reason) do
    case data["detail"] do
      detail when is_binary(detail) -> Map.merge(idle, %{reason: reason, detail: detail})
      _ -> Map.put(idle, :reason, reason)
    end
  end

  defp ended_by(idle, _data), do: idle

  # What the turn an event ends cost, in the model's shape (root Decision 769); a log
  # written before turns were counted has none.
  defp spent(state, %{"turn" => %{} = turn}) do
    Map.put(state, :turn, %{
      calls: int(turn["calls"]),
      usage: usage(turn),
      cost_micros: int(turn["cost_micros"]),
      unpriced: int(turn["unpriced"])
    })
  end

  defp spent(state, _data), do: state

  # One a person asked for with `/compact` says so; the harness's own say nothing more.
  defp compacted_note(%{"reason" => "manual"}), do: "context compacted, as /compact asked"
  defp compacted_note(_data), do: "context compacted"

  defp summarised(emit, %{"usage" => %{} = used}), do: [emit.(:call_usage, %{usage: usage(used)})]
  defp summarised(_emit, _data), do: []

  defp as(%{"profile" => profile}) when is_binary(profile), do: " as #{profile}"
  defp as(_data), do: ""

  @dimensions %{
    "turns" => :turns,
    "input" => :input,
    "output" => :output,
    "wall" => :wall,
    "context" => :context
  }
  defp dimension(name), do: Map.get(@dimensions, name, :other)

  defp limit(%{"limit" => limit}) when is_binary(limit), do: ": #{limit}"

  defp limit(%{"limit" => %{} = limit}),
    do: ": " <> Enum.map_join(limit, " ", fn {k, v} -> "#{k}=#{scalar(v)}" end)

  defp limit(_data), do: ""

  defp switch(%{"from" => from, "to" => to}) when is_binary(from) and is_binary(to),
    do: " #{from} → #{to}"

  defp switch(%{"to" => to}) when is_binary(to), do: " to #{to}"
  defp switch(_data), do: ""

  # `(project) · gains shell · loses write_file, edit_file`, from what a daemon since
  # Decision 841 says of a switch; an older one's says neither.
  defp tools_changed(data) do
    layer = if is_binary(data["layer"]), do: " (#{data["layer"]})", else: ""

    [{"gains", data["tools_added"]}, {"loses", data["tools_removed"]}]
    |> Enum.flat_map(fn
      {word, [_ | _] = tools} -> [" · #{word} " <> Enum.join(tools, ", ")]
      {_word, _none} -> []
    end)
    |> then(&Enum.join([layer | &1]))
  end

  defp to_child(%{"child_path" => [_ | _] = path}), do: " to " <> Enum.join(path, "/")
  defp to_child(%{"agent" => agent}) when is_binary(agent), do: " to #{agent}"
  defp to_child(_data), do: ""

  defp usage(%{} = usage) do
    %{
      input: int(usage["input"] || usage["input_tokens"]),
      output: int(usage["output"] || usage["output_tokens"]),
      cache_read: int(usage["cache_read"]),
      cache_write: int(usage["cache_write"])
    }
  end

  defp usage(_usage), do: %{input: 0, output: 0, cache_read: 0, cache_write: 0}

  defp int(n) when is_integer(n), do: n
  defp int(_n), do: 0

  # Text is markdown wherever it appears; a result too big to inline arrives as
  # `{blob, preview}` and the preview is what is shown until the blob is fetched.
  # `content` may be a string, a list of blocks, or a list of strings.
  defp text_of(%{"text" => text}) when is_binary(text), do: text
  defp text_of(%{"content" => content}) when is_binary(content), do: content

  defp text_of(%{"content" => content}) when is_list(content),
    do: Enum.map_join(content, "", &block_text/1)

  defp text_of(%{"message" => message}) when is_binary(message), do: message
  defp text_of(%{"message" => %{} = message}), do: text_of(message)
  defp text_of(%{"preview" => preview}) when is_binary(preview), do: preview
  defp text_of(_data), do: ""

  defp block_text(text) when is_binary(text), do: text
  defp block_text(%{"type" => "text", "text" => text}) when is_binary(text), do: text
  defp block_text(%{"text" => text}) when is_binary(text), do: text
  defp block_text(_block), do: ""

  defp call_id(data) do
    data["call_id"] || data["id"] || data["tool_call_id"] || "call"
  end

  defp input(data) do
    case data["input"] || data["args"] do
      %{} = input -> input
      value when is_binary(value) -> %{"input" => value}
      _ -> %{}
    end
  end

  defp completed(data) do
    %{
      call_id: call_id(data),
      ok: data["ok"] != false and data["error"] in [nil, false],
      content: result_text(data),
      blob: data["blob"] || get_in(data, ["result", "blob"])
    }
  end

  # A result over the inline limit comes as `{blob, preview}`; the preview goes
  # on screen right away and the blob is fetched only when the reader expands it.
  defp result_text(%{"result" => %{} = result}), do: text_of(result)
  defp result_text(%{"result" => result}) when is_binary(result), do: result
  defp result_text(data), do: text_of(data)

  defp preview(data) do
    case data["preview"] do
      preview when is_binary(preview) -> preview
      %{} = diff -> Troupe.Remote.Diff.render(diff)
      _ -> nil
    end
  end

  defp options(%{"options" => options}) when is_list(options) do
    Enum.flat_map(options, fn
      %{"label" => label} = option when is_binary(label) ->
        [%{label: label, description: option["description"]}]

      label when is_binary(label) ->
        [%{label: label, description: nil}]

      _ ->
        []
    end)
  end

  defp options(_data), do: []

  defp decision(data) do
    case data["decision"] do
      "allow" -> :allow
      "deny" -> :deny
      "allow_session" -> :allow_session
      other when is_binary(other) -> String.to_atom(other)
      _ -> :allow
    end
  end

  defp todos(data) do
    data
    |> Map.get("items", Map.get(data, "todos", []))
    |> List.wrap()
    |> Enum.map(fn
      %{} = item ->
        %{
          text: item["content"] || item["text"] || item["title"] || "",
          status: state_atom(item["status"] || "pending"),
          id: item["id"]
        }

      other when is_binary(other) ->
        %{text: other, status: :pending, id: nil}

      _ ->
        %{text: "", status: :pending, id: nil}
    end)
    |> Enum.reject(&(&1.text == ""))
  end

  defp paths(data) do
    data |> Map.get("paths", List.wrap(data["path"])) |> List.wrap() |> Enum.filter(&is_binary/1)
  end

  # Everything a card and a row show of a document; its words are read when it is opened.
  defp scratch(data) do
    name = if is_binary(data["name"]), do: data["name"], else: ""

    %{
      call_id: data["call_id"],
      name: name,
      path: if(is_binary(data["path"]), do: data["path"], else: "scratch:/" <> name),
      kind: if(is_binary(data["kind"]), do: data["kind"], else: "text"),
      title: if(is_binary(data["title"]) and data["title"] != "", do: data["title"], else: name),
      size: if(is_integer(data["size"]), do: data["size"], else: 0),
      version: if(is_integer(data["version"]), do: data["version"], else: 1)
    }
  end

  defp state_atom(value) when is_binary(value) do
    case value do
      "working" -> :working
      "waiting" -> :waiting
      "idle" -> :idle
      "thinking" -> :thinking
      "done" -> :done
      "in_progress" -> :in_progress
      "pending" -> :pending
      "cancelled" -> :cancelled
      other -> String.to_atom(other)
    end
  end

  defp state_atom(value) when is_atom(value) and not is_nil(value), do: value
  defp state_atom(_value), do: :idle

  # `moved`: the session came back in another workspace than the one it was created in,
  # in the desktop app's words.
  defp moved(%{"moved" => true}), do: " on another device"
  defp moved(_data), do: ""

  # `from` is absent where the version the session was pinned to is not known.
  defp version(%{"from" => from, "to" => to}) when is_integer(from), do: " from #{from} to #{to}"
  defp version(%{"to" => to}), do: " to #{to}"
  defp version(_data), do: ""

  defp truncated(data) do
    what =
      case data["reason"] do
        "empty" -> "the reply had no text and no tool call"
        _max_tokens -> "the reply was cut at the output cap"
      end

    then =
      cond do
        data["final"] == true -> "; giving up"
        is_integer(data["calls"]) -> "; #{data["calls"]} tool call(s) answered with an error"
        is_binary(data["note"]) -> "; asking again"
        true -> ""
      end

    what <> then
  end

  # A file the agent made for the person: where it is, on a session on this machine; on a
  # pod, the path in the session's workspace and the command that saves it here.
  defp file_ready(%{"local_path" => local}) when is_binary(local), do: "file ready: #{local}"

  defp file_ready(data) do
    path = to_string(data["path"] || "")
    "file ready in the session's workspace: #{path}; /save #{path} saves it on this machine"
  end

  # A person's own tools offered to the session (PROTOCOL.md section 8): who offered them and
  # which, since everyone in the session is entitled to know a tool runs on somebody's
  # machine. Who is their name where the event carries one, since a provider's subject may
  # be an opaque id, and the subject where not. The desktop app says the same sentence.
  defp tainted(data) do
    who =
      Enum.find([data["display_name"], data["actor"]], "somebody", &(is_binary(&1) and &1 != ""))

    said = "#{who} offered tools that run on their own machine"

    case Enum.filter(List.wrap(data["tools"]), &is_binary/1) do
      [] -> said
      tools -> "#{said}: #{Enum.join(tools, ", ")}"
    end
  end

  defp registered(who, data) do
    who = if is_binary(who), do: who, else: "somebody"

    case tool_names(data) do
      [] -> "#{who} offered the session tools from their own machine"
      tools -> "#{who} offered the session #{Enum.join(tools, ", ")}; it can call them now"
    end
  end

  # Whose tools went, how many and why, in one line: a teammate watching the session learns
  # that what ran on somebody's machine is gone, and the taint line before it stays.
  defp unregistered(who, data) do
    whose = "#{who || "somebody"}'s"
    why = left(data["reason"])

    case tool_names(data) do
      [] ->
        "#{whose} tools are no longer offered to the session#{why}"

      [tool] ->
        "#{whose} tool #{tool} is no longer offered to the session#{why}"

      tools ->
        "#{whose} #{length(tools)} tools are no longer offered to the session#{why}: " <>
          Enum.join(tools, ", ")
    end
  end

  defp left("disconnected"), do: ", because their client left"
  defp left("unregistered"), do: ", because they took their tools back"
  defp left(reason) when is_binary(reason) and reason != "", do: " (#{reason})"
  defp left(_reason), do: ""

  # A person by their name where the event's actor has one, else the subject the event
  # names; a log from before `tools_unregistered` said whose has neither.
  defp owner_of(%{"actor" => %{"kind" => "user"} = actor}, data),
    do: actor["display_name"] || actor["subject"] || owner_of(%{}, data)

  defp owner_of(_event, %{"actor" => subject}) when is_binary(subject), do: subject
  defp owner_of(_event, _data), do: nil

  defp tool_names(data), do: Enum.filter(List.wrap(data["tools"]), &is_binary/1)

  # The skipped event's own time, to the minute, as UTC: a log from before `at` was written
  # says only that one was.
  defp repaired(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, written, _offset} ->
        "An event from #{Calendar.strftime(written, "%Y-%m-%d %H:%M")} UTC could not be read and was skipped"

      {:error, _reason} ->
        repaired(nil)
    end
  end

  defp repaired(_at), do: "An event could not be read and was skipped"

  # How many of each kind, then each reason once with the files it covers: a worktree's
  # one reason fits every file, while a pod's names the file it is about. An empty list
  # says the files listed before are read now, or gone.
  defp files_skipped(files) do
    case Enum.filter(List.wrap(files), &is_map/1) do
      [] ->
        "no agent or skill file is skipped now"

      files ->
        by_reason = Enum.group_by(files, &skipped_reason/1, &skipped_file/1)

        reasons =
          files
          |> Enum.map(&skipped_reason/1)
          |> Enum.uniq()
          |> Enum.map(&(Enum.join(by_reason[&1], ", ") <> ": " <> &1))

        Enum.join([counted(files) <> " not read here:" | reasons], "\n")
    end
  end

  defp skipped_reason(file), do: to_string(file["reason"] || "not read")
  defp skipped_kind(file), do: to_string(file["kind"] || "file")
  defp skipped_file(file), do: "#{skipped_kind(file)} #{file["name"]} (#{file["path"]})"

  # `2 agents and 1 skill`, the kinds in the order the list first names them.
  defp counted(files) do
    kinds = Enum.map(files, &skipped_kind/1)
    many = Enum.frequencies(kinds)

    kinds |> Enum.uniq() |> Enum.map(&Words.count(many[&1], &1)) |> Words.and_list()
  end

  # How a person's command ended, and where it ran: a session on a plane says which
  # profile's pod, and is otherwise drawn as a local one is.
  defp user_shell(data, memory) do
    %{
      run_id: data["run_id"],
      command: to_string(data["command"] || ""),
      output: to_string(data["output"] || ""),
      status: shell_status(data["ended"]),
      exit_status: data["exit_status"],
      reason: data["reason"],
      timeout_ms: data["timeout_ms"],
      agent: data["agent"] != false,
      where: where(memory)
    }
  end

  defp shell_status("exited"), do: :exited
  defp shell_status("timeout"), do: :timeout
  defp shell_status("killed"), do: :killed
  defp shell_status(_failed_or_unknown), do: :failed

  defp where(%{isolation: :remote, profile: profile}) when is_binary(profile), do: profile
  defp where(_memory), do: nil

  # A comment on an artifact this session published, as one line: who, on which, and what.
  defp commented(data) do
    artifact = if is_map(data["artifact"]), do: data["artifact"], else: %{}
    comment = if is_map(data["comment"]), do: data["comment"], else: %{}
    author = if is_map(comment["author"]), do: comment["author"], else: %{}
    who = present(author["display_name"]) || present(author["subject"]) || "Somebody"
    title = present(artifact["title"]) || "an artifact"
    "#{who} commented on “#{title}”: #{comment["body"] || ""}"
  end

  defp visibility_changed(data) do
    who = present(data["by_name"]) || present(data["by"]) || "Its owner"

    case data["visibility"] do
      "team" ->
        "#{who} gave this session to the team: everyone on it can open it"

      _private ->
        "#{who} took this session back from the team: only they and the people invited can open it"
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  # The server's `seq` travels with every event this one durable event becomes,
  # so the journal can tell a replay from something new whatever it unfolds into.
  defp durable_event(session_id, agent, type, ts, data, seq \\ nil) do
    %Event{session_id: session_id, agent_path: agent, type: type, data: data, ts: ts, seq: seq}
  end

  defp transient(session_id, agent, type, data),
    do: Event.transient(session_id, agent, type, data)
end
